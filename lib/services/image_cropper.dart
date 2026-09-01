import 'dart:io';
import 'dart:ui' show Rect, Size;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// Arguments for [ImageCropper._cropWorker], which runs on a background
/// isolate. Every field has to be a simple value that survives the isolate
/// boundary, which is why the rect arrives as fractions rather than as a Rect.
@immutable
class _CropRequest {
  final String srcPath;
  final String outPath;
  final double left;
  final double top;
  final double width;
  final double height;

  /// Preview width/height as laid out on screen, or null to skip the
  /// field-of-view correction and map fractions straight across.
  final double? previewAspect;

  const _CropRequest({
    required this.srcPath,
    required this.outPath,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this.previewAspect,
  });
}

/// Crops a captured label photo down to the on-screen framing guide so OCR
/// only sees the label region and not the surrounding scene (desk, hands,
/// other packaging). Used for the label-capture step only — box photos are
/// sent to the damage detector full-frame.
///
/// The mapping happens in two stages, and both matter:
///
/// 1. Screen to preview frame. [CameraPreview] sits as a non-positioned child
///    of a `Stack(fit: StackFit.expand)`, which hands its internal
///    `AspectRatio` tight constraints — so the preview is stretched to fill
///    the screen rather than letterboxed. That distortion is cosmetic, but it
///    does mean the guide's fractional position on screen is also its
///    fractional position within the preview frame.
///
/// 2. Preview frame to still image. These are NOT the same field of view. Both
///    are centre crops of the same sensor output at their own aspect ratios,
///    so a 16:9 preview and a 4:3 still show different amounts of the scene.
///    Mapping fractions straight across — which is what this class used to do
///    — silently slides the crop off the region the user framed as soon as the
///    two aspects diverge. At ResolutionPreset.high they happened to match,
///    which is why the bug stayed invisible; raising the preset breaks it.
class ImageCropper {
  const ImageCropper._();

  /// Returns the path to a new cropped JPEG (`*_crop.jpg`) alongside the
  /// source. On any failure (decode error, out-of-range rect) the original
  /// [srcPath] is returned unchanged so a scan never breaks over cropping.
  ///
  /// [previewAspectRatio] is the preview's width/height *as laid out on
  /// screen* — i.e. already orientation-corrected, matching what
  /// `CameraPreview` itself computes. Pass null to fall back to the old
  /// straight-ratio mapping.
  static Future<String> cropToGuide(
    String srcPath, {
    required Size screenSize,
    required Rect guideRect,
    double? previewAspectRatio,
  }) async {
    try {
      if (screenSize.width <= 0 || screenSize.height <= 0) return srcPath;

      // Guide position as a fraction of the preview frame. See stage 1 above.
      final framed = Rect.fromLTWH(
        guideRect.left / screenSize.width,
        guideRect.top / screenSize.height,
        guideRect.width / screenSize.width,
        guideRect.height / screenSize.height,
      );

      final dir = p.dirname(srcPath);
      final base = p.basenameWithoutExtension(srcPath);
      final outPath = p.join(dir, '${base}_crop.jpg');

      // Decoding a multi-megapixel still takes long enough to drop frames, and
      // this runs while the shutter button is still showing its pressed state,
      // so it goes to a background isolate.
      final result = await compute(
        _cropWorker,
        _CropRequest(
          srcPath: srcPath,
          outPath: outPath,
          left: framed.left,
          top: framed.top,
          width: framed.width,
          height: framed.height,
          previewAspect: previewAspectRatio,
        ),
      );
      return result ?? srcPath;
    } catch (e) {
      debugPrint('cropToGuide failed for $srcPath: $e');
      return srcPath;
    }
  }

  /// Re-expresses [framed] — a rect in preview-frame fractions — as a rect in
  /// still-image fractions.
  ///
  /// Both frames are centre crops of one sensor field of view, so the narrower
  /// of the two sits inside the wider and the mapping is a centre-aligned
  /// scale along whichever axis was cropped. Aspect ratios are width/height in
  /// the orientation the image is actually displayed or stored in, so both
  /// arguments must be portrait-relative or both landscape-relative.
  @visibleForTesting
  static Rect mapPreviewToImage(
    Rect framed, {
    required double previewAspect,
    required double imageAspect,
  }) {
    if (previewAspect <= 0 || imageAspect <= 0) return framed;

    var left = framed.left;
    var top = framed.top;
    var width = framed.width;
    var height = framed.height;

    if (previewAspect > imageAspect) {
      // The preview is proportionally wider, so it was cropped vertically out
      // of the still's field of view: it maps into a band across the middle.
      final scale = imageAspect / previewAspect;
      top = (1 - scale) / 2 + top * scale;
      height *= scale;
    } else if (previewAspect < imageAspect) {
      final scale = previewAspect / imageAspect;
      left = (1 - scale) / 2 + left * scale;
      width *= scale;
    }

    return Rect.fromLTWH(left, top, width, height);
  }

  /// Runs on a background isolate. Returns the written path, or null to tell
  /// the caller to keep the original.
  static String? _cropWorker(_CropRequest req) {
    final bytes = File(req.srcPath).readAsBytesSync();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return null;

    // Ensure the pixel grid is upright before mapping fractions onto it.
    final oriented = img.bakeOrientation(decoded);
    final imgW = oriented.width;
    final imgH = oriented.height;
    if (imgW <= 0 || imgH <= 0) return null;

    final framed = Rect.fromLTWH(req.left, req.top, req.width, req.height);
    final previewAspect = req.previewAspect;
    final mapped = previewAspect == null
        ? framed
        : mapPreviewToImage(
            framed,
            previewAspect: previewAspect,
            imageAspect: imgW / imgH,
          );

    int x = (mapped.left * imgW).round();
    int y = (mapped.top * imgH).round();
    int w = (mapped.width * imgW).round();
    int h = (mapped.height * imgH).round();

    // Clamp to image bounds; bail to the original if the region is degenerate.
    x = x.clamp(0, imgW - 1);
    y = y.clamp(0, imgH - 1);
    w = w.clamp(1, imgW - x);
    h = h.clamp(1, imgH - y);
    if (w < 8 || h < 8) return null;

    final cropped = img.copyCrop(oriented, x: x, y: y, width: w, height: h);
    File(req.outPath).writeAsBytesSync(img.encodeJpg(cropped, quality: 92));
    return req.outPath;
  }
}
