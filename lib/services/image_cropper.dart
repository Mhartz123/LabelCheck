import 'dart:io';
import 'dart:ui' show Rect, Size;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// Crops a captured label photo down to the on-screen framing guide so OCR
/// only sees the label region and not the surrounding scene (desk, hands,
/// other packaging). Used for the label-capture step only — box photos are
/// sent to the damage API full-frame.
///
/// The camera preview fills the whole screen (StackFit.expand), so the guide's
/// fractional position on screen maps directly onto the captured image. We
/// therefore translate [guideRect] into image pixels by simple ratio against
/// [screenSize]. EXIF orientation is baked first so the pixel grid matches
/// what the user framed.
class ImageCropper {
  /// Returns the path to a new cropped JPEG (`*_crop.jpg`) alongside the
  /// source. On any failure (decode error, out-of-range rect) the original
  /// [srcPath] is returned unchanged so a scan never breaks over cropping.
  static Future<String> cropToGuide(
    String srcPath, {
    required Size screenSize,
    required Rect guideRect,
  }) async {
    try {
      if (screenSize.width <= 0 || screenSize.height <= 0) return srcPath;

      final bytes = await File(srcPath).readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return srcPath;

      // Ensure the pixel grid is upright before mapping screen fractions.
      final oriented = img.bakeOrientation(decoded);
      final imgW = oriented.width;
      final imgH = oriented.height;

      // Map the guide rect (logical screen px) to image px by ratio.
      int x = (guideRect.left / screenSize.width * imgW).round();
      int y = (guideRect.top / screenSize.height * imgH).round();
      int w = (guideRect.width / screenSize.width * imgW).round();
      int h = (guideRect.height / screenSize.height * imgH).round();

      // Clamp to image bounds; bail to original if the region is degenerate.
      x = x.clamp(0, imgW - 1);
      y = y.clamp(0, imgH - 1);
      w = w.clamp(1, imgW - x);
      h = h.clamp(1, imgH - y);
      if (w < 8 || h < 8) return srcPath;

      final cropped = img.copyCrop(oriented, x: x, y: y, width: w, height: h);

      final dir = p.dirname(srcPath);
      final base = p.basenameWithoutExtension(srcPath);
      final outPath = p.join(dir, '${base}_crop.jpg');
      await File(outPath).writeAsBytes(img.encodeJpg(cropped, quality: 92));
      return outPath;
    } catch (e) {
      debugPrint('cropToGuide failed for $srcPath: $e');
      return srcPath;
    }
  }
}
