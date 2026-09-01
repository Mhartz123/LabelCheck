import 'package:flutter/foundation.dart';

import '../models/scan_record.dart';
import 'date_code_parser.dart';
import 'fda_dataset_checker.dart';
import 'label_parser.dart';
import 'onnx_semantic_matcher.dart';
import 'packaging_damage_service.dart';

/// Three independent scan flows (see CameraScreen's `CameraMode`), each
/// producing its own [ScanRecord]:
///
///  • [analyzeLabel] — label-only. **Banned (warned):** the product name is
///    checked against the FDA advisory/banned list — [FdaDatasetChecker]
///    (word-overlap + fuzzy), with [OnnxSemanticMatcher] as a removable
///    last-ditch tier when the name OCR was low-confidence. A hit here (and
///    only here) means banned. **Otherwise non-compliant if any of:** the
///    printed expiration date has passed (expired); the user verified no
///    expiration date is printed on the packaging; no ingredient list was
///    detected, or the user verified none is printed on the packaging.
///    **Compliant** when none of the above fire.
///
///  • [analyzeDamage] — damage-only. Runs whichever [PackagingDamageDetector]
///    is registered for the given [PackagingType] (see
///    `packaging_damage_service.dart`). **Non-compliant** if it reports
///    severe damage (≥ [_damageConfidenceThreshold]) or scratches.
///    **Compliant** otherwise — including when the detector isn't available
///    (e.g. a packaging type with no model yet), since there's nothing to
///    flag.
///
///  • [analyzeInspection] — Inspection Mode: runs both checks above in one
///    scan and combines them into a single verdict (banned name overrides
///    everything; otherwise non-compliant if any label check OR the damage
///    check fails; compliant only if everything passes).
///
/// UI, storage, and report submission consume [ScanRecord] only.
enum ScanStage { matchingRegistry, classifying, checkingDamage }

class ComplianceEngine {
  /// The ONNX semantic matcher — removable last-ditch tier of the banned-name
  /// check. Runs only when the product-name OCR was unreliable and the dataset
  /// tier found no confident match; a hit against the FDA *warned* index means
  /// banned.
  ///
  /// DISABLED, and not merely as a precaution — this was observed happening.
  ///
  /// The shipped model's embeddings are collapsed (~1% Recall@1, mean pairwise
  /// cosine ~0.99), so nearly any query matches something in the FDA *warned*
  /// index. On a real MX3 Coffee Mix scan the front-label OCR came back as
  /// "LE NT DNE*", which is low-confidence enough to open this tier, and the
  /// tier then returned a match and the product was reported BANNED.
  ///
  /// The last-ditch gate was supposed to keep the blast radius small. It does
  /// not: the gate opens precisely when the product name was read badly, which
  /// is also when the query handed to a collapsed index is pure noise. A
  /// garbled name is the trigger AND the failure mode.
  ///
  /// Leave this false until the model is retrained and Recall@1 is verified on
  /// a held-out set. See [OnnxSemanticMatcher].
  static const bool _semanticMatcherEnabled = false;

  /// Mean OCR confidence (per ML Kit, 0..1) on the product-name crop below
  /// which the name is treated as unreliable, opening the semantic fallback.
  static const double _lowOcrConfidenceThreshold = 0.6;

  /// Minimum damage-detection confidence (0..1) for "severe" packaging damage
  /// to count as non-compliant. Scratches fail regardless of confidence.
  static const double _damageConfidenceThreshold = 0.70;

  /// Kicks off the model + FDA dataset asset loads early (e.g. from
  /// CameraScreen.initState) so the first scan's analyze call isn't stuck
  /// paying full load latency while the user is still framing photos.
  /// [packagingType] is optional — pass it (from CameraScreen, once the user
  /// has picked one) to also warm that packaging type's damage detector;
  /// omit it for a label-only scan, which has no damage step to warm.
  static void warmUp({PackagingType? packagingType}) {
    // ignore: unawaited_futures
    FdaDatasetChecker.ensureLoaded();
    if (_semanticMatcherEnabled) {
      // ignore: unawaited_futures
      OnnxSemanticMatcher.instance();
    }
    if (packagingType != null) {
      // ignore: unawaited_futures
      PackagingDamageService.warmUp(packagingType);
    }
  }

  // ── Label-only ─────────────────────────────────────────────────────────

  /// Runs the label-compliance check only. [textBySlot] maps each captured
  /// label [PhotoSlot] to the OCR text extracted from that slot's
  /// (guide-cropped) photo (see LabelParser). [combinedText] concatenates all
  /// label slots' text, used for the registry/name match.
  ///
  /// [ocrConfidence] is the mean ML Kit confidence (0..1) on the product-name
  /// crop (or null): it gates the last-ditch semantic tier.
  static Future<ScanRecord> analyzeLabel({
    required Map<PhotoSlot, String> textBySlot,
    required String combinedText,
    double? ocrConfidence,
    DateCode? dateCode,
    bool expirationDeclaredMissing = false,
    bool ingredientsDeclaredMissing = false,
    void Function(ScanStage stage)? onStageChange,
  }) async {
    final _LabelSignals s = await _computeLabelSignals(
      textBySlot: textBySlot,
      combinedText: combinedText,
      ocrConfidence: ocrConfidence,
      dateCode: dateCode,
      expirationDeclaredMissing: expirationDeclaredMissing,
      ingredientsDeclaredMissing: ingredientsDeclaredMissing,
      onStageChange: onStageChange,
    );

    final ComplianceStatus status = s.banned
        ? ComplianceStatus.banned
        : (s.expired ||
        s.expirationMissing ||
        s.expirationUnreadable ||
        s.ingredientsMissing)
        ? ComplianceStatus.nonCompliant
        : ComplianceStatus.compliant;

    return ScanRecord(
      kind: ScanKind.label,
      status: status,
      matchedKeyword: _matchedLabelKeyword(s),
      reasons: _buildLabelReasons(status: status, s: s),
      productName: s.fields.productName,
      expiration: _expirationLabel(s),
      ingredients: s.fields.ingredients,
      extractedText: combinedText,
      damageCheck: const DamageCheckResult.notPerformed(),
      packagingType: null,
      scannedAt: DateTime.now(),
    );
  }

  // ── Damage-only ────────────────────────────────────────────────────────

  /// Runs the packaging-damage check only, against whichever detector is
  /// registered for [packagingType]. [boxPhotoPaths] are the full-frame
  /// packaging shots fed to that detector.
  static Future<ScanRecord> analyzeDamage({
    required PackagingType packagingType,
    required List<String> boxPhotoPaths,
    void Function(ScanStage stage)? onStageChange,
  }) async {
    final damage =
    await _computeDamage(packagingType, boxPhotoPaths, onStageChange);
    final bool damageFails = _damageFails(damage);

    final ComplianceStatus status = damageFails
        ? ComplianceStatus.nonCompliant
        : ComplianceStatus.compliant;

    return ScanRecord(
      kind: ScanKind.damage,
      status: status,
      matchedKeyword: damageFails ? 'packaging damage' : '—',
      reasons: damageFails ? [_damageReason(damage)] : const [],
      productName: '—',
      expiration: '—',
      ingredients: '—',
      extractedText: '',
      damageCheck: damage,
      packagingType: packagingType,
      scannedAt: DateTime.now(),
    );
  }

  // ── Inspection Mode (both) ────────────────────────────────────────────

  /// Runs the label check AND the packaging-damage check in one scan,
  /// combining them into a single verdict. [textBySlot]/[combinedText]/
  /// [ocrConfidence] are the label-side inputs (see [analyzeLabel]);
  /// [packagingType]/[boxPhotoPaths] are the damage-side inputs (see
  /// [analyzeDamage]).
  static Future<ScanRecord> analyzeInspection({
    required Map<PhotoSlot, String> textBySlot,
    required String combinedText,
    required PackagingType packagingType,
    required List<String> boxPhotoPaths,
    double? ocrConfidence,
    DateCode? dateCode,
    bool expirationDeclaredMissing = false,
    bool ingredientsDeclaredMissing = false,
    void Function(ScanStage stage)? onStageChange,
  }) async {
    final _LabelSignals s = await _computeLabelSignals(
      textBySlot: textBySlot,
      combinedText: combinedText,
      ocrConfidence: ocrConfidence,
      dateCode: dateCode,
      expirationDeclaredMissing: expirationDeclaredMissing,
      ingredientsDeclaredMissing: ingredientsDeclaredMissing,
      onStageChange: onStageChange,
    );
    final damage =
    await _computeDamage(packagingType, boxPhotoPaths, onStageChange);
    final bool damageFails = _damageFails(damage);

    final ComplianceStatus status = s.banned
        ? ComplianceStatus.banned
        : (s.expired ||
        s.expirationMissing ||
        s.expirationUnreadable ||
        s.ingredientsMissing ||
        damageFails)
        ? ComplianceStatus.nonCompliant
        : ComplianceStatus.compliant;

    final reasons = <String>[
      ..._buildLabelReasons(status: status, s: s, omitFallback: true),
      if (damageFails) _damageReason(damage),
    ];
    if (status != ComplianceStatus.compliant && reasons.isEmpty) {
      reasons.add('Could not confirm compliance from the scan.');
    }

    final tags = <String>[
      if (s.expired) 'expired',
      if (s.expirationMissing) 'no expiration date',
      if (s.expirationUnreadable) 'unreadable expiration date',
      if (s.ingredientsMissing) 'no ingredient list',
      if (damageFails) 'packaging damage',
    ];

    return ScanRecord(
      kind: ScanKind.both,
      status: status,
      matchedKeyword: s.banned
          ? _matchedLabelKeyword(s)
          : (tags.isEmpty ? '—' : tags.join(', ')),
      reasons: reasons,
      productName: s.fields.productName,
      expiration: _expirationLabel(s),
      ingredients: s.fields.ingredients,
      extractedText: combinedText,
      damageCheck: damage,
      packagingType: packagingType,
      scannedAt: DateTime.now(),
    );
  }

  // ── Shared internals ──────────────────────────────────────────────────

  static Future<_LabelSignals> _computeLabelSignals({
    required Map<PhotoSlot, String> textBySlot,
    required String combinedText,
    double? ocrConfidence,
    DateCode? dateCode,
    required bool expirationDeclaredMissing,
    required bool ingredientsDeclaredMissing,
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

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    // The structured read wins when the expiration slot produced one: it knows
    // which printed value is the expiry rather than taking the first date it
    // finds, and it can say "I could not read this" as its own answer.
    final DateTime? expiryDate = dateCode != null
        ? dateCode.expiry
        : fields.expirationDate;
    final bool expired = expiryDate != null && today.isAfter(expiryDate);

    // A code that could not be read is NOT the same as a product with no
    // expiry problem. Letting it fall through as a pass is what inflates the
    // clean counts, so it fails the scan on its own terms — unless the user
    // has already verified there is no date printed at all, which is the
    // separate expirationMissing outcome.
    final bool expirationUnreadable = dateCode != null &&
        dateCode.status == DateCodeStatus.unreadable &&
        !expirationDeclaredMissing;
    // The user can verify on-camera that an element simply isn't printed on the
    // packaging; that declaration alone fails compliance (the label is absent),
    // independent of whatever OCR did or didn't read.
    final bool ingredientsMissing =
        ingredientsDeclaredMissing || !fields.ingredientsPresent;

    return _LabelSignals(
      fields: fields,
      advisoryMatch: advisoryMatch,
      semanticMatch: semanticMatch,
      banned: advisoryMatch != null || semanticMatch != null,
      expired: expired,
      expirationMissing: expirationDeclaredMissing,
      expirationUnreadable: expirationUnreadable,
      dateCode: dateCode,
      ingredientsMissing: ingredientsMissing,
    );
  }

  static Future<DamageCheckResult> _computeDamage(
      PackagingType packagingType,
      List<String> boxPhotoPaths,
      void Function(ScanStage stage)? onStageChange,
      ) async {
    onStageChange?.call(ScanStage.checkingDamage);
    return PackagingDamageService.check(packagingType, boxPhotoPaths);
  }

  static bool _damageFails(DamageCheckResult damage) =>
      damage.available &&
          damage.isDamaged &&
          (damage.maxConfidence >= _damageConfidenceThreshold ||
              damage.hasScratch);

  static String _damageReason(DamageCheckResult damage) {
    final detail = damage.hasScratch
        ? 'scratches detected'
        : 'severe damage detected '
        '(${(damage.maxConfidence * 100).toStringAsFixed(0)}% confidence)';
    return 'Packaging damage — $detail.';
  }

  static String _matchedLabelKeyword(_LabelSignals s) {
    if (s.advisoryMatch != null) return s.advisoryMatch!.productName;
    if (s.semanticMatch != null) {
      return '${s.semanticMatch!.productName} '
          '(semantic match, ${(s.semanticMatch!.score * 100).toStringAsFixed(0)}%)';
    }
    final tags = <String>[
      if (s.expired) 'expired',
      if (s.expirationMissing) 'no expiration date',
      if (s.expirationUnreadable) 'unreadable expiration date',
      if (s.ingredientsMissing) 'no ingredient list',
    ];
    return tags.isEmpty ? '—' : tags.join(', ');
  }

  /// [omitFallback] skips the "could not confirm compliance" catch-all —
  /// used by [analyzeInspection], which adds its own catch-all after also
  /// considering the damage check.
  /// What the report shows for the expiration field.
  ///
  /// "Unreadable" and "Not detected" are deliberately different strings: the
  /// first means a date was photographed and could not be parsed, which fails
  /// the scan, and the second is the old fallback for a slot with no date text
  /// in it at all.
  static String _expirationLabel(_LabelSignals s) {
    final code = s.dateCode;
    if (code == null) return s.fields.expiration;
    if (code.status == DateCodeStatus.unreadable) return 'Unreadable';
    final expiry = code.expiry;
    if (expiry == null) return s.fields.expiration;
    final month = expiry.month.toString().padLeft(2, '0');
    return '${expiry.year}-$month';
  }

  static List<String> _buildLabelReasons({
    required ComplianceStatus status,
    required _LabelSignals s,
    bool omitFallback = false,
  }) {
    if (status == ComplianceStatus.compliant) return const [];

    if (status == ComplianceStatus.banned) {
      if (s.advisoryMatch != null) {
        return [
          'Matches FDA ${s.advisoryMatch!.advisoryNumber} (${s.advisoryMatch!.category}): '
              '"${s.advisoryMatch!.productName}".',
          'Product should not be sold or consumed. Report to the FDA hotline.',
        ];
      }
      return [
        'Semantically matches FDA-flagged product '
            '"${s.semanticMatch!.productName}" '
            '(${(s.semanticMatch!.score * 100).toStringAsFixed(0)}% similarity).',
        'Product should not be sold or consumed. Report to the FDA hotline.',
      ];
    }

    // Non-compliant: list each failing label check.
    final reasons = <String>[];
    if (s.expired) {
      reasons.add('Expired — the printed expiration date '
          '(${s.fields.expiration}) has passed.');
    }
    if (s.expirationMissing) {
      reasons.add('No expiration date is printed on the packaging '
          '(verified by the user).');
    }
    if (s.expirationUnreadable) {
      final note = s.dateCode?.note;
      reasons.add('The expiration date could not be read from the photo, so '
          'it could not be checked${note == null ? '' : ' — $note'}');
    }
    if (s.ingredientsMissing) {
      reasons.add('No ingredient list was detected on the label.');
    }
    if (reasons.isEmpty && !omitFallback) {
      reasons.add('Could not confirm compliance from the scanned label.');
    }
    return reasons;
  }
}

/// Intermediate label-side signals shared by [ComplianceEngine.analyzeLabel]
/// and [ComplianceEngine.analyzeInspection].
class _LabelSignals {
  final LabelFields fields;
  final FdaAdvisoryMatch? advisoryMatch;
  final SemanticMatch? semanticMatch;
  final bool banned;
  final bool expired;
  final bool expirationMissing;

  /// The date code was photographed but could not be read. Distinct from
  /// [expirationMissing], which means the user verified none is printed.
  final bool expirationUnreadable;

  final bool ingredientsMissing;
  final DateCode? dateCode;

  const _LabelSignals({
    required this.fields,
    required this.advisoryMatch,
    required this.semanticMatch,
    required this.banned,
    required this.expired,
    required this.expirationMissing,
    this.expirationUnreadable = false,
    required this.ingredientsMissing,
    this.dateCode,
  });
}