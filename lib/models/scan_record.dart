import 'package:flutter/material.dart';

/// Compliance classification for a saved record.
enum ComplianceStatus { compliant, nonCompliant, banned }

/// Which check(s) a [ScanRecord] represents. Label checking and box/damage
/// checking are two independent scan flows (see CameraScreen/
/// ComplianceEngine), each producing its own record — [label] or [damage].
/// [both] exists only to keep loading old records (saved before this split)
/// working: they carry both label and damage data in one record.
enum ScanKind { label, damage, both }

/// Which kind of packaging a damage check ([ScanKind.damage] or
/// [ScanKind.both]) was run against. The user picks one on
/// PackagingTypeScreen before the camera opens for any flow that includes a
/// damage step.
///
/// Only [box] has a real detection model right now ([hasModel]) — [foil] and
/// [bottle] are wired up end-to-end as placeholders (capture flow, picker UI,
/// record storage) so a future model only needs a new
/// `PackagingDamageDetector` registered in `packaging_damage_service.dart`;
/// nothing else in the app needs to change.
enum PackagingType { box, foil, bottle }

extension PackagingTypeX on PackagingType {
  String get label {
    switch (this) {
      case PackagingType.box:
        return 'Box';
      case PackagingType.foil:
        return 'Foil';
      case PackagingType.bottle:
        return 'Bottle';
    }
  }

  /// Whether a real detection model is wired up for this packaging type yet.
  /// See the class doc above — [foil] and [bottle] are placeholders until
  /// their models ship.
  bool get hasModel => this == PackagingType.box;

  IconData get icon {
    switch (this) {
      case PackagingType.box:
        return Icons.inventory_2_outlined;
      case PackagingType.foil:
        return Icons.texture_outlined;
      case PackagingType.bottle:
        return Icons.liquor_outlined;
    }
  }
}

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

/// The four packaging-capture slots for the damage step. These are
/// full-frame shots of the whole item (no crop, no OCR) sent to whichever
/// [PackagingDamageDetector] handles the chosen [PackagingType] — a separate
/// concern from the label slots above. Reused for every packaging type: the
/// four-angle capture shape doesn't change, only which detector processes it.
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

/// One damage box the detector found, with where it sits on the photo.
///
/// [left]/[top]/[width]/[height] are **normalised to 0..1** against the source
/// photo *after* EXIF orientation is baked in — the same space Flutter's
/// `Image.file` and the PDF renderer draw in. Storing fractions rather than
/// pixels means an overlay lines up at any display size, and a record stays
/// readable if the photo is later resized.
///
/// [sourceIndex] is the position of the photo this box came from within the
/// packaging photos for the scan, in [BoxSlot] order with skipped slots
/// omitted — i.e. the same ordering as `ScanStore.boxPhotosInOrder`, so a
/// saved record can find its way back to the right image.
class DamageDetection {
  final String label;
  final double confidence;
  final double left;
  final double top;
  final double width;
  final double height;
  final int sourceIndex;

  const DamageDetection({
    required this.label,
    required this.confidence,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this.sourceIndex,
  });

  double get right => left + width;
  double get bottom => top + height;

  /// Confidence as a whole percentage, for display ("Dent 87%").
  String get confidenceLabel => '${(confidence * 100).round()}%';

  Map<String, dynamic> toJson() => {
    'label': label,
    'confidence': confidence,
    'left': left,
    'top': top,
    'width': width,
    'height': height,
    'sourceIndex': sourceIndex,
  };

  factory DamageDetection.fromJson(Map<String, dynamic> json) =>
      DamageDetection(
        label: json['label'] as String? ?? 'Damage',
        confidence: (json['confidence'] as num?)?.toDouble() ?? 0.0,
        left: (json['left'] as num?)?.toDouble() ?? 0.0,
        top: (json['top'] as num?)?.toDouble() ?? 0.0,
        width: (json['width'] as num?)?.toDouble() ?? 0.0,
        height: (json['height'] as num?)?.toDouble() ?? 0.0,
        sourceIndex: (json['sourceIndex'] as num?)?.toInt() ?? 0,
      );
}

/// Result of a packaging-damage check via a `PackagingDamageDetector` (see
/// `packaging_damage_service.dart`). [available] is false when the check
/// couldn't run at all — no network/backend for a live model, or (for
/// [PackagingType.foil]/[PackagingType.bottle] today) because no model is
/// wired up yet — distinct from [isDamaged], which is only meaningful when
/// [available] is true.
class DamageCheckResult {
  final bool available;
  final String message;
  final bool isDamaged;
  final List<String> detections;

  /// Where each detection sits on its source photo, for drawing an overlay.
  ///
  /// Parallel to [detections] in content but richer: [detections] stays the
  /// plain class-name list the dashboard payload and older records use, while
  /// [boxes] adds geometry and per-detection confidence. Empty for records
  /// saved before boxes were captured, and for detectors that report classes
  /// without geometry — so always treat an empty [boxes] on a damaged record
  /// as "no overlay available", never as "no damage".
  final List<DamageDetection> boxes;

  /// Highest detection confidence (0..1) the damage model returned across all
  /// packaging photos, used to gate whether "severe" damage counts against
  /// compliance. 0 when nothing was detected or confidence wasn't reported.
  final double maxConfidence;

  const DamageCheckResult({
    required this.available,
    required this.message,
    this.isDamaged = false,
    this.detections = const [],
    this.boxes = const [],
    this.maxConfidence = 0.0,
  });

  const DamageCheckResult.placeholder()
      : available = false,
        message = 'Damage detection not yet available',
        isDamaged = false,
        detections = const [],
        boxes = const [],
        maxConfidence = 0.0;

  /// Used for label-only scans, where the damage check was never run because
  /// the user chose "Check Labels" rather than a damage-inclusive flow.
  const DamageCheckResult.notPerformed()
      : available = false,
        message = 'Damage check not performed for this scan.',
        isDamaged = false,
        detections = const [],
        boxes = const [],
        maxConfidence = 0.0;

  /// True if any detection class reads as a scratch (scratches count against
  /// compliance regardless of confidence).
  bool get hasScratch =>
      detections.any((d) => d.toLowerCase().contains('scratch'));

  /// One line naming what was found and how sure the model was, e.g.
  /// "Dent x2 (up to 87%), Scratches (72%)". Falls back to the bare class
  /// list for records saved before per-detection confidence was stored.
  String get detectionSummary {
    if (boxes.isEmpty) return detections.toSet().join(', ');
    final byLabel = <String, List<DamageDetection>>{};
    for (final d in boxes) {
      byLabel.putIfAbsent(d.label, () => []).add(d);
    }
    return byLabel.entries.map((e) {
      final best = e.value
          .map((d) => d.confidence)
          .reduce((a, b) => a > b ? a : b);
      final pct = '${(best * 100).round()}%';
      return e.value.length > 1
          ? '${e.key} ×${e.value.length} (up to $pct)'
          : '${e.key} ($pct)';
    }).join(', ');
  }

  Map<String, dynamic> toJson() => {
    'available': available,
    'message': message,
    'isDamaged': isDamaged,
    'detections': detections,
    'boxes': boxes.map((b) => b.toJson()).toList(),
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
      boxes: (json['boxes'] as List?)
          ?.map((b) => DamageDetection.fromJson(b as Map<String, dynamic>))
          .toList() ??
          const [],
      maxConfidence: (json['maxConfidence'] as num?)?.toDouble() ?? 0.0,
    );
  }
}

/// Structured result of a scan — produced by ComplianceEngine and persisted
/// as each record's data.json.
class ScanRecord {
  final ScanKind kind;
  final ComplianceStatus status;
  final String matchedKeyword;
  final List<String> reasons;
  final String productName;
  final String expiration;
  final String ingredients;
  final String extractedText;
  final DamageCheckResult damageCheck;

  /// Which packaging type the damage check ran against — null for a
  /// label-only ([ScanKind.label]) record, or for records saved before this
  /// field existed.
  final PackagingType? packagingType;

  final DateTime scannedAt;

  const ScanRecord({
    required this.kind,
    required this.status,
    required this.matchedKeyword,
    required this.reasons,
    required this.productName,
    required this.expiration,
    required this.ingredients,
    required this.extractedText,
    required this.damageCheck,
    this.packagingType,
    required this.scannedAt,
  });

  /// Whether this record carries label data (product/expiration/ingredients)
  /// worth displaying — true for [ScanKind.label] and legacy [ScanKind.both]
  /// records, false for a damage-only scan.
  bool get hasLabelData => kind != ScanKind.damage;

  /// Whether this record carries a damage check worth displaying — true for
  /// [ScanKind.damage] and legacy [ScanKind.both] records, false for a
  /// label-only scan.
  bool get hasDamageData => kind != ScanKind.label;

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
    'kind': kind.name,
    'status': statusLabel,
    'matchedKeyword': matchedKeyword,
    'reasons': reasons,
    'productName': productName,
    'expiration': expiration,
    'ingredients': ingredients,
    'extractedText': extractedText,
    'damageCheck': damageCheck.toJson(),
    if (packagingType != null) 'packagingType': packagingType!.name,
    'scannedAt': scannedAt.toIso8601String(),
  };

  factory ScanRecord.fromJson(Map<String, dynamic> json) => ScanRecord(
    kind: _kindFromName(json['kind'] as String?),
    status: _statusFromLabel(json['status'] as String? ?? ''),
    matchedKeyword: json['matchedKeyword'] as String? ?? '—',
    reasons: (json['reasons'] as List?)?.cast<String>() ?? const [],
    productName: json['productName'] as String? ?? '—',
    expiration: json['expiration'] as String? ?? '—',
    ingredients: json['ingredients'] as String? ?? '—',
    extractedText: json['extractedText'] as String? ?? '',
    damageCheck:
    DamageCheckResult.fromJson(json['damageCheck'] as Map<String, dynamic>?),
    packagingType: _packagingTypeFromName(json['packagingType'] as String?),
    scannedAt: DateTime.tryParse(json['scannedAt'] as String? ?? '') ??
        DateTime.now(),
  );

  static ComplianceStatus _statusFromLabel(String s) {
    if (s == 'COMPLIANT') return ComplianceStatus.compliant;
    if (s == 'WARNING / BANNED') return ComplianceStatus.banned;
    return ComplianceStatus.nonCompliant;
  }

  /// Records saved before the label/damage split didn't store a `kind` at
  /// all — those are treated as [ScanKind.both] so they keep displaying both
  /// their label and damage sections exactly as before.
  static ScanKind _kindFromName(String? name) {
    if (name == null) return ScanKind.both;
    return ScanKind.values.firstWhere(
          (k) => k.name == name,
      orElse: () => ScanKind.both,
    );
  }

  static PackagingType? _packagingTypeFromName(String? name) {
    if (name == null) return null;
    for (final t in PackagingType.values) {
      if (t.name == name) return t;
    }
    return null;
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