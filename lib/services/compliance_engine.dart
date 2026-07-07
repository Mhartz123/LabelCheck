import '../models/scan_record.dart';
import 'damage_detection_service.dart';
import 'fda_checker.dart' as fda;
import 'label_parser.dart';

/// Orchestrates a full scan analysis: keyword-based compliance
/// classification, heuristic label field parsing, and a (placeholder)
/// packaging damage check, combined into one [ScanRecord].
///
/// This is the single seam to edit later when swapping the keyword
/// classifier for the DistilBERT/FDA-dataset model — everything downstream
/// (UI, storage, report submission) consumes [ScanRecord], not the raw
/// engine.
class ComplianceEngine {
  static Future<ScanRecord> analyze({
    required String combinedText,
    required List<String> photoPaths,
  }) async {
    final fda.ScanResult keywordResult = fda.FdaChecker.classify(combinedText);
    final LabelFields fields = LabelParser.parse(combinedText);
    final DamageCheckResult damage =
        await DamageDetectionService.check(photoPaths);

    final status = _mapStatus(keywordResult.status);
    final reasons = _buildReasons(
      status: status,
      matchedKeyword: keywordResult.matchedKeyword,
      combinedText: combinedText,
      fields: fields,
    );

    return ScanRecord(
      status: status,
      matchedKeyword: keywordResult.matchedKeyword,
      reasons: reasons,
      productName: fields.productName,
      brand: fields.brand,
      expiration: fields.expiration,
      ingredients: fields.ingredients,
      extractedText: combinedText,
      damageCheck: damage,
      scannedAt: DateTime.now(),
    );
  }

  static ComplianceStatus _mapStatus(fda.ComplianceStatus s) {
    switch (s) {
      case fda.ComplianceStatus.compliant:
        return ComplianceStatus.compliant;
      case fda.ComplianceStatus.nonCompliant:
        return ComplianceStatus.nonCompliant;
      case fda.ComplianceStatus.banned:
        return ComplianceStatus.banned;
    }
  }

  static final RegExp _fdaRegNumberRegex = RegExp(
    r'fda\s*(reg(?:istration)?\.?\s*(no\.?|number)?)?\s*[:\-]?\s*[a-z0-9\-]{6,}',
    caseSensitive: false,
  );

  static List<String> _buildReasons({
    required ComplianceStatus status,
    required String matchedKeyword,
    required String combinedText,
    required LabelFields fields,
  }) {
    if (status == ComplianceStatus.compliant) return const [];

    if (status == ComplianceStatus.banned) {
      return [
        'Contains "$matchedKeyword" — an FDA banned/recalled substance or product.',
        'Product should not be sold or consumed. Report to the FDA hotline.',
      ];
    }

    final reasons = <String>[];
    final lower = combinedText.toLowerCase();

    if (!_fdaRegNumberRegex.hasMatch(combinedText)) {
      reasons.add('No valid FDA Registration No. detected on label.');
    }

    final hasStorageOrDosage = lower.contains('store') ||
        lower.contains('storage') ||
        lower.contains('dosage') ||
        lower.contains('directions for use') ||
        lower.contains('take ');
    if (!hasStorageOrDosage) {
      reasons.add('Required storage & dosage directives missing.');
    }

    if (fields.expiration == 'Not detected') {
      reasons.add('No expiration date detected on label.');
    }

    if (matchedKeyword == 'insufficient label information') {
      reasons.add(
          'Not enough label information could be read to confirm compliance.');
    } else if (reasons.isEmpty) {
      reasons.add('Flagged phrase detected: "$matchedKeyword".');
    }

    return reasons;
  }
}
