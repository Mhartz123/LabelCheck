import 'package:flutter/foundation.dart';

import '../models/scan_record.dart';
import 'damage_detection_service.dart';
import 'fda_dataset_checker.dart';
import 'label_parser.dart';
import 'onnx_semantic_matcher.dart';

/// Orchestrates a full scan analysis into one [ScanRecord] using a fixed
/// compliance pipeline:
///
///  • **Banned (warned):** the product name is checked against the FDA
///    advisory/banned list — [FdaDatasetChecker] (word-overlap + fuzzy), with
///    [OnnxSemanticMatcher] as a removable last-ditch tier when the name OCR
///    was low-confidence. A hit here (and only here) means banned. If the name
///    isn't on the list, it is not flagged as banned.
///  • **Otherwise non-compliant if any of:**
///      - the printed expiration date has passed (expired);
///      - the user verified no expiration date is printed on the packaging;
///      - no ingredient list was detected, or the user verified none is printed
///        on the packaging;
///      - the box-damage model reports severe damage (≥ [_damageConfidenceThreshold])
///        or scratches ([DamageDetectionService]).
///  • **Compliant** when none of the above fire.
///
/// UI, storage, and report submission consume [ScanRecord] only.
enum ScanStage { matchingRegistry, classifying, checkingDamage }

class ComplianceEngine {
  /// The ONNX semantic matcher — removable last-ditch tier of the banned-name
  /// check. Runs only when the product-name OCR was unreliable and the dataset
  /// tier found no confident match; a hit against the FDA *warned* index means
  /// banned.
  ///
  /// NOTE: the shipped model's embeddings are collapsed (~1% Recall@1), so any
  /// scan that actually reaches it will likely be mis-flagged until the model
  /// is retrained/verified. The last-ditch gate keeps that blast radius small;
  /// set this to false to remove the tier entirely. See [OnnxSemanticMatcher].
  static const bool _semanticMatcherEnabled = true;

  /// Mean OCR confidence (per ML Kit, 0..1) on the product-name crop below
  /// which the name is treated as unreliable, opening the semantic fallback.
  static const double _lowOcrConfidenceThreshold = 0.6;

  /// Minimum damage-detection confidence (0..1) for "severe" packaging damage
  /// to count as non-compliant. Scratches fail regardless of confidence.
  static const double _damageConfidenceThreshold = 0.70;

  /// Kicks off the model + FDA dataset asset loads early (e.g. from
  /// CameraScreen.initState) so the first scan's analyze() call isn't stuck
  /// paying full load latency while the user is still framing photos.
  static void warmUp() {
    // ignore: unawaited_futures
    FdaDatasetChecker.ensureLoaded();
    // ignore: unawaited_futures
    DamageDetectionService.warmUp();
    if (_semanticMatcherEnabled) {
      // ignore: unawaited_futures
      OnnxSemanticMatcher.instance();
    }
  }

  /// [textBySlot] maps each captured label [PhotoSlot] to the OCR text
  /// extracted from that slot's (guide-cropped) photo (see LabelParser).
  /// [combinedText] concatenates all label slots' text, used for the
  /// registry/name match.
  ///
  /// [boxPhotoPaths] are the separate full-frame box shots fed to the damage
  /// API. [ocrConfidence] is the mean ML Kit confidence (0..1) on the
  /// product-name crop (or null): it gates the last-ditch semantic tier.
  static Future<ScanRecord> analyze({
    required Map<PhotoSlot, String> textBySlot,
    required String combinedText,
    required List<String> boxPhotoPaths,
    double? ocrConfidence,
    bool expirationDeclaredMissing = false,
    bool ingredientsDeclaredMissing = false,
    void Function(ScanStage stage)? onStageChange,
  }) async {
    onStageChange?.call(ScanStage.matchingRegistry);
    await FdaDatasetChecker.ensureLoaded();

    final LabelFields fields = LabelParser.parse(textBySlot);
    final FdaMatchOutcome advisoryOutcome =
        FdaDatasetChecker.matchOutcome(combinedText);
    final FdaAdvisoryMatch? advisoryMatch = advisoryOutcome.match;

    // Last-ditch semantic name check: runs ONLY when the product-name OCR was
    // unreliable *and* the dataset tier produced no confident match.
    onStageChange?.call(ScanStage.classifying);
    SemanticMatch? semanticMatch;
    final bool ocrUnreliable =
        ocrConfidence != null && ocrConfidence < _lowOcrConfidenceThreshold;
    final bool runSemantic =
        _semanticMatcherEnabled && ocrUnreliable && advisoryMatch == null;
    if (runSemantic) {
      try {
        final matcher = await OnnxSemanticMatcher.instance();
        semanticMatch = matcher.match(combinedText);
      } catch (e) {
        debugPrint('Semantic matcher unavailable: $e');
      }
    }

    // Packaging damage runs on the dedicated box photos only.
    onStageChange?.call(ScanStage.checkingDamage);
    final DamageCheckResult damage =
        await DamageDetectionService.check(boxPhotoPaths);

    // ── Combine signals into a compliance verdict ──────────────────────────
    final bool banned = advisoryMatch != null || semanticMatch != null;

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final bool expired = fields.expirationDate != null &&
        today.isAfter(fields.expirationDate!);
    // The user can verify on-camera that an element simply isn't printed on the
    // packaging; that declaration alone fails compliance (the label is absent),
    // independent of whatever OCR did or didn't read.
    final bool expirationMissing = expirationDeclaredMissing;
    final bool ingredientsMissing =
        ingredientsDeclaredMissing || !fields.ingredientsPresent;
    final bool damageFails = damage.available &&
        damage.isDamaged &&
        (damage.maxConfidence >= _damageConfidenceThreshold ||
            damage.hasScratch);

    final ComplianceStatus status = banned
        ? ComplianceStatus.banned
        : (expired || expirationMissing || ingredientsMissing || damageFails)
            ? ComplianceStatus.nonCompliant
            : ComplianceStatus.compliant;

    final reasons = _buildReasons(
      status: status,
      advisoryMatch: advisoryMatch,
      semanticMatch: semanticMatch,
      fields: fields,
      expired: expired,
      expirationMissing: expirationMissing,
      ingredientsMissing: ingredientsMissing,
      damageFails: damageFails,
      damage: damage,
    );

    return ScanRecord(
      status: status,
      matchedKeyword: _matchedLabel(
        advisoryMatch: advisoryMatch,
        semanticMatch: semanticMatch,
        expired: expired,
        expirationMissing: expirationMissing,
        ingredientsMissing: ingredientsMissing,
        damageFails: damageFails,
      ),
      reasons: reasons,
      productName: fields.productName,
      expiration: fields.expiration,
      ingredients: fields.ingredients,
      extractedText: combinedText,
      damageCheck: damage,
      scannedAt: DateTime.now(),
    );
  }

  static String _matchedLabel({
    required FdaAdvisoryMatch? advisoryMatch,
    required SemanticMatch? semanticMatch,
    required bool expired,
    required bool expirationMissing,
    required bool ingredientsMissing,
    required bool damageFails,
  }) {
    if (advisoryMatch != null) return advisoryMatch.productName;
    if (semanticMatch != null) {
      return '${semanticMatch.productName} '
          '(semantic match, ${(semanticMatch.score * 100).toStringAsFixed(0)}%)';
    }
    final tags = <String>[
      if (expired) 'expired',
      if (expirationMissing) 'no expiration date',
      if (ingredientsMissing) 'no ingredient list',
      if (damageFails) 'packaging damage',
    ];
    return tags.isEmpty ? '—' : tags.join(', ');
  }

  static List<String> _buildReasons({
    required ComplianceStatus status,
    required FdaAdvisoryMatch? advisoryMatch,
    required SemanticMatch? semanticMatch,
    required LabelFields fields,
    required bool expired,
    required bool expirationMissing,
    required bool ingredientsMissing,
    required bool damageFails,
    required DamageCheckResult damage,
  }) {
    if (status == ComplianceStatus.compliant) return const [];

    if (status == ComplianceStatus.banned) {
      if (advisoryMatch != null) {
        return [
          'Matches FDA ${advisoryMatch.advisoryNumber} (${advisoryMatch.category}): '
              '"${advisoryMatch.productName}".',
          'Product should not be sold or consumed. Report to the FDA hotline.',
        ];
      }
      return [
        'Semantically matches FDA-flagged product '
            '"${semanticMatch!.productName}" '
            '(${(semanticMatch.score * 100).toStringAsFixed(0)}% similarity).',
        'Product should not be sold or consumed. Report to the FDA hotline.',
      ];
    }

    // Non-compliant: list each failing check.
    final reasons = <String>[];
    if (expired) {
      reasons.add(
          'Expired — the printed expiration date (${fields.expiration}) has passed.');
    }
    if (expirationMissing) {
      reasons.add('No expiration date is printed on the packaging '
          '(verified by the user).');
    }
    if (ingredientsMissing) {
      reasons.add('No ingredient list was detected on the label.');
    }
    if (damageFails) {
      final detail = damage.hasScratch
          ? 'scratches detected'
          : 'severe damage detected '
              '(${(damage.maxConfidence * 100).toStringAsFixed(0)}% confidence)';
      reasons.add('Packaging damage — $detail.');
    }
    if (reasons.isEmpty) {
      reasons.add('Could not confirm compliance from the scanned label.');
    }
    return reasons;
  }
}
