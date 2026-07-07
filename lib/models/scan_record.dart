import 'package:flutter/material.dart';

/// Compliance classification for a saved record.
enum ComplianceStatus { compliant, nonCompliant, banned }

/// The four fixed capture slots for a single product scan.
enum PhotoSlot { front, back, side1, side2 }

extension PhotoSlotX on PhotoSlot {
  String get fileBaseName {
    switch (this) {
      case PhotoSlot.front:
        return 'front';
      case PhotoSlot.back:
        return 'back';
      case PhotoSlot.side1:
        return 'side1';
      case PhotoSlot.side2:
        return 'side2';
    }
  }
}

/// Placeholder result for the future YOLOv8 packaging-damage model.
/// [available] stays false until the real model is wired into
/// [DamageDetectionService].
class DamageCheckResult {
  final bool available;
  final String message;

  const DamageCheckResult({required this.available, required this.message});

  const DamageCheckResult.placeholder()
      : available = false,
        message = 'Damage detection not yet available';

  Map<String, dynamic> toJson() => {
        'available': available,
        'message': message,
      };

  factory DamageCheckResult.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const DamageCheckResult.placeholder();
    return DamageCheckResult(
      available: json['available'] as bool? ?? false,
      message: json['message'] as String? ??
          'Damage detection not yet available',
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
  final String brand;
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
    required this.brand,
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
        'brand': brand,
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
        brand: json['brand'] as String? ?? '—',
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
