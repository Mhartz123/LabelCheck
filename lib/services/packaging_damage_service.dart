import '../models/scan_record.dart';
import 'damage_detection_service.dart';

/// ── HOW TO PLUG IN A NEW MODEL ──────────────────────────────────────────
///
/// Damage detection is split one [PackagingDamageDetector] per
/// [PackagingType], registered in [PackagingDamageService]. Only
/// [PackagingType.box] has a real model today ([BoxDamageDetector], backed
/// by the on-device YOLOv5nu ONNX model in `damage_detection_service.dart`).
/// [PackagingType.foil] and [PackagingType.bottle] are placeholders
/// ([FoilDamageDetector], [BottleDamageDetector]) that report themselves as
/// unavailable — the capture flow, picker UI, and record storage for both
/// are already fully wired up, so dropping in a real model later is a
/// two-step change and nothing else in the app needs to know:
///
///   1. Write a new class implementing [PackagingDamageDetector] (model load,
///      preprocessing, inference, and NMS/threshold logic all live inside
///      it — [BoxDamageDetector] / `damage_detection_service.dart` is a
///      template for the shape this usually takes).
///   2. Register it in [PackagingDamageService._detectors] below, replacing
///      the placeholder, e.g.:
///         PackagingType.foil: FoilYoloDetector(),
///
/// ComplianceEngine, CameraScreen, and every UI screen only ever go through
/// [PackagingDamageService.check] / [PackagingDamageService.warmUp] — they
/// never reference a concrete detector, so none of them change.

/// Runs a damage check against a set of full-frame packaging photos for one
/// [PackagingType]. Implementations should never throw — report failures via
/// [DamageCheckResult.available] = false instead, so a scan always completes.
abstract class PackagingDamageDetector {
  Future<DamageCheckResult> check(List<String> photoPaths);

  /// Optional: kick off model loading early (see
  /// [PackagingDamageService.warmUp]). Default is a no-op for detectors with
  /// nothing to preload (e.g. placeholders).
  Future<void> warmUp() async {}
}

/// The real, on-device YOLOv5nu detector for cardboard boxes. Thin wrapper
/// around the existing [DamageDetectionService] so that service's
/// preprocessing/inference/NMS logic doesn't need to move or change.
class BoxDamageDetector implements PackagingDamageDetector {
  @override
  Future<DamageCheckResult> check(List<String> photoPaths) =>
      DamageDetectionService.check(photoPaths);

  @override
  Future<void> warmUp() => DamageDetectionService.warmUp();
}

/// Placeholder for foil packaging (sachets, blister packs, etc). No model is
/// wired up yet — every check reports [DamageCheckResult.available] = false
/// with an explanatory message, exactly like a real detector reporting a
/// load failure, so downstream UI needs no special-casing.
class FoilDamageDetector extends PackagingDamageDetector {
  @override
  Future<DamageCheckResult> check(List<String> photoPaths) async {
    return const DamageCheckResult(
      available: false,
      message:
      'Foil damage detection isn\'t available yet — no model has been '
          'trained for this packaging type.',
    );
  }
}

/// Placeholder for bottle packaging. See [FoilDamageDetector] — same shape,
/// swap in a real detector here once one exists.
class BottleDamageDetector extends PackagingDamageDetector {
  @override
  Future<DamageCheckResult> check(List<String> photoPaths) async {
    return const DamageCheckResult(
      available: false,
      message:
      'Bottle damage detection isn\'t available yet — no model has been '
          'trained for this packaging type.',
    );
  }
}

/// Facade the rest of the app calls through — routes each check to the
/// detector registered for that [PackagingType]. See the module doc above
/// for how to swap a placeholder for a real model.
class PackagingDamageService {
  static final Map<PackagingType, PackagingDamageDetector> _detectors = {
    PackagingType.box: BoxDamageDetector(),
    PackagingType.foil: FoilDamageDetector(),
    PackagingType.bottle: BottleDamageDetector(),
  };

  /// Swaps in a different detector for a packaging type — this is the one
  /// line a future model integration needs to change, if you'd rather patch
  /// it here than edit the map literal above directly.
  static void register(PackagingType type, PackagingDamageDetector detector) {
    _detectors[type] = detector;
  }

  static Future<DamageCheckResult> check(
      PackagingType type,
      List<String> photoPaths,
      ) {
    final detector = _detectors[type];
    if (detector == null) {
      return Future.value(const DamageCheckResult(
        available: false,
        message: 'No damage detector registered for this packaging type.',
      ));
    }
    return detector.check(photoPaths);
  }

  /// Warms up just the detector for [type] — called from CameraScreen once
  /// the user has picked a packaging type, so only the relevant model (if
  /// any) pays load latency.
  static Future<void> warmUp(PackagingType type) async {
    try {
      await _detectors[type]?.warmUp();
    } catch (_) {
      // Warm-up failures surface again (and get reported properly) the next
      // time check() actually runs.
    }
  }
}