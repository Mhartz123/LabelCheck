import '../models/scan_record.dart';

/// Placeholder seam for the future YOLOv8 packaging-damage detection model.
///
/// Swap the body of [check] for a real inference call once the model is
/// trained/exported — keep the signature (`List<String>` photo paths in,
/// `Future<DamageCheckResult>` out) unchanged so callers don't need to change.
class DamageDetectionService {
  static Future<DamageCheckResult> check(List<String> photoPaths) async {
    // TODO: replace with YOLOv8 inference once the model is trained/exported.
    return const DamageCheckResult.placeholder();
  }
}
