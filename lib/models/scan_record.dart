import 'package:flutter/material.dart';

/// Compliance classification for a saved record.
enum ComplianceStatus { compliant, nonCompliant, banned }

/// The three fixed label-capture slots for a single product scan. Each slot's
/// OCR text is routed straight to its own record field (see LabelParser)
/// instead of being guessed out of one combined blob of text. These are the
/// close-up label shots — cropped to the framing guide before OCR. The
/// ingredient-list slot feeds the "ingredient list present?" compliance check.
enum PhotoSlot { front, expiration, ingredients }

extension PhotoSlotX on PhotoSlot {
  String get fileBaseName {
    switch (this) {
      case PhotoSlot.front:
        return 'front';
      case PhotoSlot.expiration:
        return 'expiration';
      case PhotoSlot.ingredients:
        return 'ingredients';
    }
  }
}

/// The four box-capture slots for the packaging-damage step. These are
/// full-frame shots of the whole box (no crop, no OCR) sent to the YOLOv8
/// damage API — a separate concern from the label slots above.
enum BoxSlot { front, side1, side2, back }

extension BoxSlotX on BoxSlot {
  String get fileBaseName {
    switch (this) {
      case BoxSlot.front:
        return 'box_front';
      case BoxSlot.side1:
        return 'box_side1';
      case BoxSlot.side2:
        return 'box_side2';
      case BoxSlot.back:
        return 'box_back';
    }
  }
}

/// Result of a packaging-damage check via [DamageDetectionService] (backed
/// by the labelcheck-apii Roboflow workflow). [available] is false when the
/// check couldn't run at all (no network, backend unreachable) — distinct
/// from [isDamaged], which is only meaningful when [available] is true.
class DamageCheckResult {
  final bool available;
  final String message;
  final bool isDamaged;
  final List<String> detections;

  /// Highest detection confidence (0..1) the damage API returned across all
  /// box photos, used to gate whether "severe" damage counts against
  /// compliance. 0 when nothing was detected or confidence wasn't reported.
  final double maxConfidence;

  const DamageCheckResult({
    required this.available,
    required this.message,
    this.isDamaged = false,
    this.detections = const [],
    this.maxConfidence = 0.0,
  });

  const DamageCheckResult.placeholder()
      : available = false,
        message = 'Damage detection not yet available',
        isDamaged = false,
        detections = const [],
        maxConfidence = 0.0;

  /// True if any detection class reads as a scratch (scratches count against
  /// compliance regardless of confidence).
  bool get hasScratch =>
      detections.any((d) => d.toLowerCase().contains('scratch'));

  Map<String, dynamic> toJson() => {
        'available': available,
        'message': message,
        'isDamaged': isDamaged,
        'detections': detections,
        'maxConfidence': maxConfidence,
      };

  factory DamageCheckResult.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const DamageCheckResult.placeholder();
    return DamageCheckResult(
      available: json['available'] as bool? ?? false,
      message: json['message'] as String? ??
          'Damage detection not yet available',
      isDamaged: json['isDamaged'] as bool? ?? false,
      detections: (json['detections'] as List?)?.cast<String>() ?? const [],
      maxConfidence: (json['maxConfidence'] as num?)?.toDouble() ?? 0.0,
    );
  }
}

/// Structured result of a scan — produced by ComplianceEngine and persisted
/// as each record's data.json.
class ScanRecord {
  final ComplianceStatus status;
  final String matchedKeyword;
  final List<String> reasons;
  final String productName;
  final String expiration;
  final String ingredients;
  final String extractedText;
  final DamageCheckResult damageCheck;
  final DateTime scannedAt;

  const ScanRecord({
    required this.status,
    required this.matchedKeyword,
    required this.reasons,
    required this.productName,
    required this.expiration,
    required this.ingredients,
    required this.extractedText,
    required this.damageCheck,
    required this.scannedAt,
  });

  String get statusLabel {
    switch (status) {
      case ComplianceStatus.compliant:
        return 'COMPLIANT';
      case ComplianceStatus.nonCompliant:
        return 'NON-COMPLIANT';
      case ComplianceStatus.banned:
        return 'WARNING / BANNED';
    }
  }

  Map<String, dynamic> toJson() => {
        'status': statusLabel,
        'matchedKeyword': matchedKeyword,
        'reasons': reasons,
        'productName': productName,
        'expiration': expiration,
        'ingredients': ingredients,
        'extractedText': extractedText,
        'damageCheck': damageCheck.toJson(),
        'scannedAt': scannedAt.toIso8601String(),
      };

  factory ScanRecord.fromJson(Map<String, dynamic> json) => ScanRecord(
        status: _statusFromLabel(json['status'] as String? ?? ''),
        matchedKeyword: json['matchedKeyword'] as String? ?? '—',
        reasons: (json['reasons'] as List?)?.cast<String>() ?? const [],
        productName: json['productName'] as String? ?? '—',
        expiration: json['expiration'] as String? ?? '—',
        ingredients: json['ingredients'] as String? ?? '—',
        extractedText: json['extractedText'] as String? ?? '',
        damageCheck:
            DamageCheckResult.fromJson(json['damageCheck'] as Map<String, dynamic>?),
        scannedAt: DateTime.tryParse(json['scannedAt'] as String? ?? '') ??
            DateTime.now(),
      );

  static ComplianceStatus _statusFromLabel(String s) {
    if (s == 'COMPLIANT') return ComplianceStatus.compliant;
    if (s == 'WARNING / BANNED') return ComplianceStatus.banned;
    return ComplianceStatus.nonCompliant;
  }
}

/// UI-facing presentation helpers for a [ScanRecord]'s status.
extension ScanRecordUi on ScanRecord {
  Color get statusColor {
    switch (status) {
      case ComplianceStatus.compliant:
        return const Color(0xFF4CAF50);
      case ComplianceStatus.nonCompliant:
        return const Color(0xFFFF9800);
      case ComplianceStatus.banned:
        return const Color(0xFFF44336);
    }
  }

  IconData get statusIcon {
    switch (status) {
      case ComplianceStatus.compliant:
        return Icons.check_circle;
      case ComplianceStatus.nonCompliant:
        return Icons.warning;
      case ComplianceStatus.banned:
        return Icons.dangerous;
    }
  }

  String get statusTitle {
    switch (status) {
      case ComplianceStatus.compliant:
        return 'Compliant';
      case ComplianceStatus.nonCompliant:
        return 'Non-Compliant';
      case ComplianceStatus.banned:
        return 'Banned';
    }
  }

  String get note {
    switch (status) {
      case ComplianceStatus.compliant:
        return 'Product is compliant with the FDA and is safe to consume. Please refer to instructions / professionals with regards to safe dosage.';
      case ComplianceStatus.nonCompliant:
        return 'Product is non-compliant with the FDA and is inadvisable to consume. Please refer to the local FDA hotline near you to report this occurrence.';
      case ComplianceStatus.banned:
        return 'Product is banned by the FDA, dangerous to consume. Please immediately refer to the local FDA hotline near you to report this occurrence.';
    }
  }

  Color get noteColor {
    switch (status) {
      case ComplianceStatus.compliant:
        return Colors.black54;
      case ComplianceStatus.nonCompliant:
      case ComplianceStatus.banned:
        return const Color(0xFFE57373);
    }
  }
}
