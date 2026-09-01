import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:ui_prototype/services/ocr_preprocessor.dart';

img.Image _filled(int width, int height, int level) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(level, level, level));
  return image;
}

void _block(img.Image image, int x, int y, int w, int h, int level) {
  img.fillRect(
    image,
    x1: x,
    y1: y,
    x2: x + w - 1,
    y2: y + h - 1,
    color: img.ColorRgb8(level, level, level),
  );
}

/// Dot-matrix character strokes on a low-contrast ground: ink at 120 on paper
/// at 150, a spread of 30 against the ~210 a normal black-on-white print gives.
img.Image _dottedCode() {
  final image = _filled(160, 48, 150);
  for (var c = 0; c < 5; c++) {
    final x = 16 + c * 28;
    for (final strokeX in <int>[x, x + 10]) {
      for (var y = 12; y < 36; y += 3) {
        _block(image, strokeX, y, 3, 2, 120);
      }
    }
  }
  return image;
}

/// A single horizontal stroke printed as discrete dots, 2px wide on a 3px
/// pitch — a one-pixel gap, which is what the dot-merge kernel is sized for.
img.Image _dottedStroke() {
  final image = _filled(160, 48, 150);
  for (var x = 20; x < 140; x += 3) {
    _block(image, x, 20, 2, 8, 120);
  }
  return image;
}

/// Two dotted characters with a genuine character gap between them. The merge
/// has to close the gaps inside each one without welding the two together.
img.Image _twoDottedCharacters() {
  final image = _filled(160, 48, 150);
  for (final start in <int>[20, 90]) {
    for (var x = start; x < start + 50; x += 3) {
      _block(image, x, 20, 2, 8, 120);
    }
  }
  return image;
}

/// A bold glyph with an open counter, like an O. Large solid type is what the
/// morphology kernel would smear if it were left on for the product name.
img.Image _glyphWithCounter() {
  final image = _filled(160, 48, 235);
  _block(image, 40, 8, 48, 32, 30);
  _block(image, 52, 16, 24, 16, 235);
  return image;
}

int _luma(img.Image image, int x, int y) {
  final pixel = image.getPixel(x, y);
  // run() hands back a single-channel image, where only .r carries the value.
  if (image.numChannels == 1) return pixel.r.round();
  return ((pixel.r * 77 + pixel.g * 150 + pixel.b * 29) / 256).round();
}

/// Number of separate dark runs along the scanline at [y].
int _darkRuns(img.Image image, int y, {int threshold = 128}) {
  var runs = 0;
  var inRun = false;
  for (var x = 0; x < image.width; x++) {
    final dark = _luma(image, x, y) < threshold;
    if (dark && !inRun) runs++;
    inRun = dark;
  }
  return runs;
}

void main() {
  group('capture quality gate', () {
    test('a flat grey frame fails, and says why in words a user can act on',
        () {
      final quality =
          OcrPreprocessor.assess(_filled(120, 40, 128), OcrProfile.dateCode);

      expect(quality.passes, isFalse);
      expect(quality.contrastSpread, 0);
      expect(quality.failureReason, contains('faint'));
      expect(quality.failureReason, contains('light'));
    });

    test('a blown-out frame is reported as glare, not as faint', () {
      final quality =
          OcrPreprocessor.assess(_filled(120, 40, 253), OcrProfile.dateCode);

      expect(quality.passes, isFalse);
      expect(quality.blownRatio, 1.0);
      expect(quality.failureReason, contains('Glare'));
    });

    test('a sharp low-contrast code fails the gate a blur check would pass',
        () {
      final quality = OcrPreprocessor.assess(_dottedCode(), OcrProfile.dateCode);

      expect(quality.contrastSpread, lessThan(kDateCodeMinContrastSpread));
      expect(quality.sharpness, greaterThan(kDateCodeMinSharpness));
      expect(quality.passes, isFalse);
      expect(quality.failureReason, contains('faint'));
    });

    test('the profiles carry different thresholds', () {
      expect(OcrProfileParams.dateCode.closeGapPixels, kDateCodeCloseGapPixels);
      expect(OcrProfileParams.productName.closeGapPixels, 0);
      expect(OcrProfileParams.ingredients.closeGapPixels, 0);
    });
  });

  group('enhancement pipeline', () {
    test('raises the contrast spread of a low-contrast dotted code', () {
      final source = _dottedCode();
      final before = OcrPreprocessor.assess(source, OcrProfile.dateCode);
      final after = OcrPreprocessor.assess(
        OcrPreprocessor.run(source, OcrProfile.dateCode),
        OcrProfile.dateCode,
      );

      expect(after.contrastSpread, greaterThan(before.contrastSpread));
      expect(after.contrastSpread,
          greaterThanOrEqualTo(kDateCodeMinContrastSpread));
    });

    test('upscales a small crop by the profile ceiling', () {
      final source = _dottedCode();

      final dateCode = OcrPreprocessor.run(source, OcrProfile.dateCode);
      expect(dateCode.width, source.width * kDateCodeUpscale);
      expect(dateCode.height, source.height * kDateCodeUpscale);

      final productName = OcrPreprocessor.run(source, OcrProfile.productName);
      expect(productName.width, source.width * kProductNameUpscale);
    });

    test('a crop that already meets the target height is not upscaled', () {
      // What a higher capture resolution produces. Interpolating this further
      // adds no detail and puts a needlessly large buffer through the O(n.k)
      // morphology, so the factor has to fall away on its own.
      const params = OcrProfileParams.dateCode;
      expect(params.upscaleFor(kDateCodeTargetHeight), 1);
      expect(params.upscaleFor(kDateCodeTargetHeight * 2), 1);

      final tall = _filled(320, kDateCodeTargetHeight, 128);
      final out = OcrPreprocessor.run(tall, OcrProfile.dateCode);
      expect(out.height, tall.height);
      expect(out.width, tall.width);
    });

    test('the close kernel tracks the upscale factor', () {
      // Calibration is stated in source pixels, so the kernel has to grow with
      // the factor to keep reaching the same distance on the original crop.
      // At the measured 4x this must still come out as the value that was
      // tuned by hand, 9.
      const params = OcrProfileParams.dateCode;
      expect(params.closeKernelFor(4), 9);
      expect(params.closeKernelFor(2), 5);
      expect(params.closeKernelFor(1), 3);

      // Profiles with morphology off stay off at every factor.
      expect(OcrProfileParams.productName.closeKernelFor(4), 0);
      expect(OcrProfileParams.ingredients.closeKernelFor(4), 0);
    });

    test('merges a dotted stroke into a continuous one', () {
      final source = _dottedStroke();
      final before = _darkRuns(source, 24);
      final after = OcrPreprocessor.run(source, OcrProfile.dateCode);

      // 40 discrete dots in, one continuous stroke out — which is the shape
      // ML Kit's recognizer was trained on and a dot cloud is not.
      expect(before, 40);
      expect(_darkRuns(after, 24 * kDateCodeUpscale), 1);
    });

    test('merges within a character without welding characters together', () {
      final after =
          OcrPreprocessor.run(_twoDottedCharacters(), OcrProfile.dateCode);

      expect(_darkRuns(after, 24 * kDateCodeUpscale), 2);
    });

    test('the product-name profile leaves a large glyph unsmeared', () {
      final out =
          OcrPreprocessor.run(_glyphWithCounter(), OcrProfile.productName);
      const scale = kProductNameUpscale;

      // The counter stays open and the strokes stay solid: two dark runs
      // across the middle of the glyph, with light between them.
      expect(_darkRuns(out, 24 * scale), 2);
      expect(_luma(out, 64 * scale, 24 * scale), greaterThan(200));
      expect(_luma(out, 44 * scale, 24 * scale), lessThan(60));
    });

    test('leaves blank board blank instead of stretching its noise to black',
        () {
      // A tile holding nothing but paper has a tiny contrast range of its own.
      // Stretched on the same terms as a tile holding text, that range expands
      // to full scale and the blank board comes out black — which then reads
      // as a stroke and merges into whatever is beside it.
      final out =
          OcrPreprocessor.run(_glyphWithCounter(), OcrProfile.productName);
      const scale = kProductNameUpscale;

      for (final x in <int>[4, 12, 20, 30, 120, 140, 155]) {
        expect(
          _luma(out, x * scale, 24 * scale),
          greaterThan(200),
          reason: 'background at source x=$x should stay light',
        );
      }
    });
  });
}
