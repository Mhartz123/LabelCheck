import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:ui_prototype/services/image_cropper.dart';

/// The guide as it sits on screen for the expiration slot: a wide, short band
/// across the middle. Expressed as fractions of the preview frame.
const Rect _centredBand = Rect.fromLTWH(0.25, 0.45, 0.5, 0.1);

void main() {
  group('preview to image mapping', () {
    test('matching aspects map straight across', () {
      final out = ImageCropper.mapPreviewToImage(
        _centredBand,
        previewAspect: 9 / 16,
        imageAspect: 9 / 16,
      );
      expect(out, _centredBand);
    });

    test('a 16:9 preview over a 4:3 still narrows along the cropped axis', () {
      // Portrait: the preview is 9:16 (0.5625), the still 3:4 (0.75). Both are
      // centre crops of one sensor field of view, so the taller-and-narrower
      // preview shows the middle 75% of the still's width and all its height.
      final out = ImageCropper.mapPreviewToImage(
        _centredBand,
        previewAspect: 9 / 16,
        imageAspect: 3 / 4,
      );

      expect(out.width, closeTo(0.5 * 0.75, 1e-9));
      expect(out.left, closeTo(0.125 + 0.25 * 0.75, 1e-9));

      // The uncropped axis is untouched.
      expect(out.top, closeTo(0.45, 1e-9));
      expect(out.height, closeTo(0.1, 1e-9));
    });

    test('the correction is the opposite way round when the still is narrower',
        () {
      final out = ImageCropper.mapPreviewToImage(
        _centredBand,
        previewAspect: 3 / 4,
        imageAspect: 9 / 16,
      );

      expect(out.height, closeTo(0.1 * 0.75, 1e-9));
      expect(out.top, closeTo(0.125 + 0.45 * 0.75, 1e-9));
      expect(out.left, closeTo(0.25, 1e-9));
      expect(out.width, closeTo(0.5, 1e-9));
    });

    test('a centred rect stays centred whatever the aspects', () {
      const centred = Rect.fromLTWH(0.25, 0.25, 0.5, 0.5);
      for (final aspect in <double>[9 / 16, 3 / 4, 1.0, 16 / 9]) {
        final out = ImageCropper.mapPreviewToImage(
          centred,
          previewAspect: 9 / 16,
          imageAspect: aspect,
        );
        expect(out.center.dx, closeTo(0.5, 1e-9), reason: 'aspect $aspect');
        expect(out.center.dy, closeTo(0.5, 1e-9), reason: 'aspect $aspect');
      }
    });

    test('the mapped rect never escapes the image', () {
      // A guide pinned hard against an edge is the case that used to slide the
      // crop off the region the user framed.
      const edge = Rect.fromLTWH(0.0, 0.0, 1.0, 0.2);
      final out = ImageCropper.mapPreviewToImage(
        edge,
        previewAspect: 9 / 16,
        imageAspect: 3 / 4,
      );

      expect(out.left, greaterThanOrEqualTo(0.0));
      expect(out.top, greaterThanOrEqualTo(0.0));
      expect(out.right, lessThanOrEqualTo(1.0));
      expect(out.bottom, lessThanOrEqualTo(1.0));
    });

    test('a degenerate aspect is passed through rather than throwing', () {
      expect(
        ImageCropper.mapPreviewToImage(_centredBand,
            previewAspect: 0, imageAspect: 0.75),
        _centredBand,
      );
    });
  });
}
