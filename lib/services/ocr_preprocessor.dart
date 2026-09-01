import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// Which of the three guide-cropped label regions a capture belongs to. The
/// crops have different print characteristics and must not share one pipeline:
/// the dot-merge kernel that rescues an inkjet date code smears the large
/// solid glyphs of a brand name.
enum OcrProfile { productName, dateCode, ingredients }

// ── Calibrated parameters ───────────────────────────────────────────────────
// Hand-tuned against sample packaging photos. Nothing here is fitted or
// learned; these are constants a human picked and can re-pick. They are named
// rather than inlined precisely because re-tuning against a larger sample set
// is expected.

/// Upper bound on the upscale factor per profile. These are ceilings, not
/// fixed multipliers: the factor actually applied is derived from the source
/// crop's height so that a bigger capture is not blown up past the point of
/// usefulness. See [kDateCodeTargetHeight].
const int kDateCodeUpscale = 4;
const int kProductNameUpscale = 2;
const int kIngredientsUpscale = 2;

/// Height, in pixels, that the pipeline aims to hand ML Kit.
///
/// These are exactly the working heights the fixed multipliers produced at the
/// old ResolutionPreset.high geometry (a ~140px-tall date-code crop at 4x, a
/// ~250px-tall name crop at 2x), so at that capture size behaviour is
/// unchanged. Above it the factor drops instead of the cost exploding: the
/// morphology in step 4 is O(n.k) over four passes, and at a 3x larger capture
/// a fixed 4x upscale would put a 7.4-megapixel buffer through it — seconds of
/// work on the minimum-spec Cortex-A53, for detail the sensor already resolved.
const int kDateCodeTargetHeight = 560;
const int kProductNameTargetHeight = 500;
const int kIngredientsTargetHeight = 500;

const int kTileGrid = 8;
const int kStretchLowPercentile = 5;
const int kStretchHighPercentile = 95;

// Dot gap the merge in step 4 has to close, measured in pixels of the ORIGINAL
// crop rather than of the upscaled buffer.
//
// A kernel of side k closes a gap of up to k-1 pixels in the upscaled image,
// so it reaches (k-1)/upscale pixels of the original. Expressing the setting
// as the source-pixel gap makes the kernel fall out of the upscale factor
// (`gap * upscale + 1`) and keeps the two in step now that the factor varies:
// at the calibrated 4x this yields 9, which is the value that was measured.
// The brief's table specifies 5, which reaches only one source pixel at 4x and
// so merges nothing at any dot pitch — step 4 becomes a no-op.
//
// CAVEAT worth re-measuring: the gap is stated in source pixels, but a higher
// capture resolution resolves the same physical gap across MORE source pixels,
// so this constant is itself resolution-dependent. It was measured at
// ResolutionPreset.high. Re-derive it from the evaluation set before trusting
// step 4 at ultraHigh.
const int kDateCodeCloseGapPixels = 2;
const int kProductNameCloseGapPixels = 0;
const int kIngredientsCloseGapPixels = 0;

const double kDateCodeUnsharpAmount = 1.6;
const double kProductNameUnsharpAmount = 1.4;
const double kIngredientsUnsharpAmount = 1.0;

const int kDateCodeMinContrastSpread = 50;
const int kProductNameMinContrastSpread = 60;
const int kIngredientsMinContrastSpread = 40;

const double kDateCodeMinSharpness = 80;
const double kProductNameMinSharpness = 100;
const double kIngredientsMinSharpness = 60;

/// Crop height the sharpness thresholds above were measured at.
///
/// Laplacian variance is NOT scale-free. The same physical blur spread over
/// more pixels produces a smaller second derivative per pixel, so raising the
/// capture resolution drags the number down on a photo that is no less sharp.
/// Measured on a real capture after the resolution change, an ingredients crop
/// scoring 51 against a threshold of 60 still gave an essentially perfect read
/// — the threshold had stopped meaning anything.
///
/// So the crop is box-averaged back down to roughly this height before the
/// variance is taken, which keeps the hand-measured thresholds valid whatever
/// the capture resolution. These are the crop heights the guides produced at
/// ResolutionPreset.high, where the thresholds were set.
const int kDateCodeSharpnessHeight = 140;
const int kProductNameSharpnessHeight = 250;
const int kIngredientsSharpnessHeight = 250;

const double kDateCodeMaxBlownRatio = 0.03;
const double kProductNameMaxBlownRatio = 0.05;
const double kIngredientsMaxBlownRatio = 0.05;

/// Luma at or above which a pixel counts as blown out.
const int kBlownLevel = 250;

/// A tile whose own contrast range is below this fraction of the whole crop's
/// range carries no text, only paper and sensor noise. Stretching it anyway
/// expands that noise to full scale and turns blank board black, which is the
/// job a real CLAHE clip limit does; this is the cheap equivalent.
const double kTileSpreadFloorFraction = 0.25;

/// Radius of the box blur used inside the unsharp mask. Applied twice, which
/// approximates a Gaussian closely enough for stroke-edge recovery.
const int kUnsharpBlurRadius = 2;

/// Quality of the temp JPEG handed to ML Kit. High, because this file exists
/// only to cross the plugin boundary and is deleted straight after.
const int kEnhancedJpegQuality = 95;

/// Per-profile parameter set. See the calibration table in the thesis.
class OcrProfileParams {
  /// Ceiling on the upscale factor. The applied factor comes from
  /// [upscaleFor].
  final int maxUpscale;

  /// Height [upscaleFor] aims the upscaled buffer at.
  final int targetHeight;

  final int tileGrid;
  final int stretchLowPercentile;
  final int stretchHighPercentile;

  /// Dot gap step 4 must close, in pixels of the source crop. Zero disables
  /// the morphology entirely.
  final int closeGapPixels;

  /// Height the crop is normalized to before sharpness is measured.
  final int sharpnessHeight;

  final double unsharpAmount;
  final int minContrastSpread;
  final double minSharpness;
  final double maxBlownRatio;

  const OcrProfileParams({
    required this.maxUpscale,
    required this.targetHeight,
    required this.tileGrid,
    required this.stretchLowPercentile,
    required this.stretchHighPercentile,
    required this.closeGapPixels,
    required this.sharpnessHeight,
    required this.unsharpAmount,
    required this.minContrastSpread,
    required this.minSharpness,
    required this.maxBlownRatio,
  });

  /// Upscale factor for a crop [sourceHeight] pixels tall: enough to reach
  /// [targetHeight], never more than [maxUpscale], never less than 1.
  ///
  /// A capture that already exceeds the target is left at its own resolution.
  /// Interpolation cannot add detail the sensor did not record, so past that
  /// point a larger factor buys nothing and costs quadratically.
  int upscaleFor(int sourceHeight) {
    if (sourceHeight <= 0) return 1;
    final wanted = (targetHeight / sourceHeight).round();
    return wanted.clamp(1, maxUpscale);
  }

  /// Side of the morphological kernel at a given [upscale], odd by
  /// construction. Zero when the profile disables the step.
  int closeKernelFor(int upscale) {
    if (closeGapPixels <= 0) return 0;
    final side = closeGapPixels * upscale + 1;
    return side.isEven ? side + 1 : side;
  }

  /// The full pipeline. Everything in it was tuned for this crop.
  static const OcrProfileParams dateCode = OcrProfileParams(
    maxUpscale: kDateCodeUpscale,
    targetHeight: kDateCodeTargetHeight,
    tileGrid: kTileGrid,
    stretchLowPercentile: kStretchLowPercentile,
    stretchHighPercentile: kStretchHighPercentile,
    closeGapPixels: kDateCodeCloseGapPixels,
    sharpnessHeight: kDateCodeSharpnessHeight,
    unsharpAmount: kDateCodeUnsharpAmount,
    minContrastSpread: kDateCodeMinContrastSpread,
    minSharpness: kDateCodeMinSharpness,
    maxBlownRatio: kDateCodeMaxBlownRatio,
  );

  /// Upscale + local stretch + unsharp. Morphology off: the brand name is
  /// large solid type and the kernel would fill its counters.
  static const OcrProfileParams productName = OcrProfileParams(
    maxUpscale: kProductNameUpscale,
    targetHeight: kProductNameTargetHeight,
    tileGrid: kTileGrid,
    stretchLowPercentile: kStretchLowPercentile,
    stretchHighPercentile: kStretchHighPercentile,
    closeGapPixels: kProductNameCloseGapPixels,
    sharpnessHeight: kProductNameSharpnessHeight,
    unsharpAmount: kProductNameUnsharpAmount,
    minContrastSpread: kProductNameMinContrastSpread,
    minSharpness: kProductNameMinSharpness,
    maxBlownRatio: kProductNameMaxBlownRatio,
  );

  /// Cheapest path — only the presence of a list is checked downstream, so a
  /// light stretch is enough. Morphology and unsharp both off.
  static const OcrProfileParams ingredients = OcrProfileParams(
    maxUpscale: kIngredientsUpscale,
    targetHeight: kIngredientsTargetHeight,
    tileGrid: kTileGrid,
    stretchLowPercentile: kStretchLowPercentile,
    stretchHighPercentile: kStretchHighPercentile,
    closeGapPixels: kIngredientsCloseGapPixels,
    sharpnessHeight: kIngredientsSharpnessHeight,
    unsharpAmount: kIngredientsUnsharpAmount,
    minContrastSpread: kIngredientsMinContrastSpread,
    minSharpness: kIngredientsMinSharpness,
    maxBlownRatio: kIngredientsMaxBlownRatio,
  );

  static OcrProfileParams of(OcrProfile profile) => switch (profile) {
        OcrProfile.dateCode => dateCode,
        OcrProfile.productName => productName,
        OcrProfile.ingredients => ingredients,
      };
}

/// Legibility of a capture, measured on three axes that fail independently.
///
/// Sharpness and legibility are not the same thing: a photo can be perfectly
/// in focus and still unreadable because the ink barely differs from the
/// board. A blur-only gate passes exactly the captures that fail hardest.
class CaptureQuality {
  /// Variance of the Laplacian over the crop. Low means out of focus.
  final double sharpness;

  /// p95 - p5 of the luma histogram. Normal black-on-white print sits around
  /// 210-220; debossed and dot-matrix marking comes in near 60-80.
  final int contrastSpread;

  /// Fraction of pixels at or above [kBlownLevel].
  final double blownRatio;

  final bool passes;

  /// User-facing, and actionable rather than diagnostic — it has to tell the
  /// user what to physically do differently, not what the number was.
  final String? failureReason;

  const CaptureQuality({
    required this.sharpness,
    required this.contrastSpread,
    required this.blownRatio,
    required this.passes,
    this.failureReason,
  });
}

/// Deterministic image arithmetic run around the ML Kit call. ML Kit wraps a
/// frozen pretrained model that cannot be trained or configured for accuracy,
/// so every gain available here comes from handing it a crop that looks more
/// like what it was already trained on.
class OcrPreprocessor {
  const OcrPreprocessor._();

  // ── Capture quality gate ─────────────────────────────────────────────────

  /// Measures [src] against [profile]'s thresholds.
  ///
  /// This is the only part of the pipeline that adds information, because it
  /// is the only part that can ask for another photo. Everything else just
  /// redistributes what is already in the frame.
  static CaptureQuality assess(img.Image src, OcrProfile profile) {
    final params = OcrProfileParams.of(profile);
    final scan = _scan(src);
    final total = scan.width * scan.height;
    if (total == 0) {
      return CaptureQuality(
        sharpness: 0,
        contrastSpread: 0,
        blownRatio: 0,
        passes: false,
        failureReason: _faintMessage(profile),
      );
    }

    final low = _percentile(scan.histogram, total, params.stretchLowPercentile);
    final high =
        _percentile(scan.histogram, total, params.stretchHighPercentile);
    final spread = high - low;
    final blownRatio = scan.blownCount / total;
    final sharpness = _normalizedLaplacianVariance(
        scan.luma, scan.width, scan.height, params.sharpnessHeight);

    // Glare is checked before contrast because a blown panel also reads as low
    // contrast, and "too faint" would send the user looking for more light —
    // the opposite of the fix.
    String? reason;
    if (blownRatio > params.maxBlownRatio) {
      reason = _glareMessage(profile);
    } else if (spread < params.minContrastSpread) {
      reason = _faintMessage(profile);
    } else if (sharpness < params.minSharpness) {
      reason = _blurMessage(profile);
    }

    return CaptureQuality(
      sharpness: sharpness,
      contrastSpread: spread,
      blownRatio: blownRatio,
      passes: reason == null,
      failureReason: reason,
    );
  }

  static String _faintMessage(OcrProfile profile) => switch (profile) {
        OcrProfile.dateCode =>
          'Date code too faint — try light coming from the side',
        OcrProfile.productName =>
          'Label too faint — try light coming from the side',
        OcrProfile.ingredients =>
          'Ingredient list too faint — try light coming from the side',
      };

  static String _blurMessage(OcrProfile profile) => switch (profile) {
        OcrProfile.dateCode =>
          'Too blurry — hold steady and tap the code to focus',
        OcrProfile.productName =>
          'Too blurry — hold steady and tap the label to focus',
        OcrProfile.ingredients =>
          'Too blurry — hold steady and tap the list to focus',
      };

  static String _glareMessage(OcrProfile profile) =>
      'Glare on the pack — tilt the phone slightly';

  // ── Enhancement pipeline ─────────────────────────────────────────────────

  /// Returns an enhanced greyscale copy of [src] for [profile].
  ///
  /// The step order is load-bearing and must not be rearranged.
  static img.Image run(img.Image src, OcrProfile profile) {
    final params = OcrProfileParams.of(profile);

    // Bake any EXIF orientation into the pixels and clear the tag. ML Kit
    // reads EXIF off the file it is handed, so a tag surviving into the temp
    // JPEG would rotate an already upright crop a second time.
    final upright = img.bakeOrientation(src);

    // 1 and 2. One luma buffer, cubically upscaled. Every step below works on
    //    this rather than on img.Image, because per-pixel getPixel/setPixel
    //    over a multi-megapixel crop is far too slow in Dart.
    //
    //    Luma is a fixed linear combination of the channels and cubic
    //    interpolation is itself linear, so interpolating luma and taking the
    //    luma of an interpolated image are the same operation up to rounding.
    //    Doing it in this order interpolates one channel instead of three and
    //    skips the image package's per-Pixel accessors, which measured at
    //    1638ms of an 1807ms total for a 340x210 crop — an order of magnitude
    //    over the budget on its own. What the step order actually requires is
    //    that the upscale precede the morphology in step 4, so the kernel has
    //    sub-dot resolution to work with, and it still does.
    final scan = _scan(upright);
    final upscale = params.upscaleFor(scan.height);
    final w = scan.width * upscale;
    final h = scan.height * upscale;
    var buf = upscale <= 1
        ? scan.luma
        : _upscaleCubic(scan.luma, scan.width, scan.height, upscale);

    // 3. Local contrast stretch. Global stretching fails on these panels
    //    because the lighting across them is uneven — it clips one end while
    //    leaving the other flat.
    final sourceTotal = scan.width * scan.height;
    final globalSpread =
        _percentile(scan.histogram, sourceTotal, params.stretchHighPercentile) -
            _percentile(scan.histogram, sourceTotal, params.stretchLowPercentile);
    buf = _localContrastStretch(
      buf,
      w,
      h,
      params.tileGrid,
      params.stretchLowPercentile,
      params.stretchHighPercentile,
      globalSpread,
    );

    // 4. Dot merge, turning clouds of discrete dots into continuous strokes.
    //    The kernel tracks the upscale factor so it keeps reaching the same
    //    distance in source pixels as the factor varies with capture size.
    final closeKernel = params.closeKernelFor(upscale);
    if (closeKernel > 1) {
      buf = _close(buf, w, h, closeKernel);
    }

    // 5. Unsharp, recovering the stroke edges softened by steps 1 and 3.
    if (params.unsharpAmount > 1.0) {
      buf = _unsharp(buf, w, h, params.unsharpAmount);
    }

    // 6. Back to an img.Image. Freshly constructed, so it carries no EXIF.
    return img.Image.fromBytes(
      width: w,
      height: h,
      bytes: buf.buffer,
      numChannels: 1,
    );
  }

  /// Writes [image] to a JPEG inside [directory] and returns its path.
  ///
  /// InputImage.fromBytes needs exact format metadata and is fragile across
  /// devices, so the enhanced crop crosses the plugin boundary as a file and
  /// InputImage.fromFilePath. [directory] is a parameter rather than a
  /// path_provider lookup, so this stays dependency-free and testable. The
  /// caller deletes the file once recognition returns.
  static Future<String> writeTempJpeg(
    img.Image image, {
    required String directory,
    String prefix = 'ocr',
  }) async {
    final name = '${prefix}_${DateTime.now().microsecondsSinceEpoch}.jpg';
    final path = p.join(directory, name);
    await File(path)
        .writeAsBytes(img.encodeJpg(image, quality: kEnhancedJpegQuality));
    return path;
  }

  // ── Luma buffer and statistics ───────────────────────────────────────────

  /// Builds the luma buffer, its 256-bin histogram and the blown-pixel count
  /// in a single pass over the source pixels.
  static _LumaScan _scan(img.Image src) {
    final w = src.width;
    final h = src.height;
    final n = w * h;
    final luma = Uint8List(n);
    final histogram = Int32List(256);
    var blown = 0;

    if (src.numChannels >= 3) {
      final rgb = src.getBytes(order: img.ChannelOrder.rgb);
      for (var i = 0, j = 0; i < n; i++, j += 3) {
        // 77/150/29 are 0.299/0.587/0.114 scaled to 256, so the usual luma
        // weighting without touching floating point.
        final v = (rgb[j] * 77 + rgb[j + 1] * 150 + rgb[j + 2] * 29) >> 8;
        luma[i] = v;
        histogram[v]++;
        if (v >= kBlownLevel) blown++;
      }
    } else {
      final gray = src.getBytes();
      final stride = src.numChannels;
      for (var i = 0, j = 0; i < n; i++, j += stride) {
        final v = gray[j];
        luma[i] = v;
        histogram[v]++;
        if (v >= kBlownLevel) blown++;
      }
    }

    return _LumaScan(luma, w, h, histogram, blown);
  }

  /// The [percent]th percentile level, read off the histogram rather than by
  /// sorting.
  static int _percentile(Int32List histogram, int total, int percent) {
    if (total <= 0) return 0;
    final target = (total * percent) ~/ 100;
    var cumulative = 0;
    for (var v = 0; v < 256; v++) {
      cumulative += histogram[v];
      if (cumulative > target) return v;
    }
    return 255;
  }

  /// Laplacian variance measured at a fixed scale, so the thresholds mean the
  /// same thing at every capture resolution. See [kDateCodeSharpnessHeight].
  static double _normalizedLaplacianVariance(
    Uint8List luma,
    int w,
    int h,
    int referenceHeight,
  ) {
    if (referenceHeight <= 0 || h <= 0) {
      return _laplacianVariance(luma, w, h);
    }
    final factor = (h / referenceHeight).round();
    if (factor <= 1) return _laplacianVariance(luma, w, h);

    final dw = w ~/ factor;
    final dh = h ~/ factor;
    if (dw < 3 || dh < 3) return _laplacianVariance(luma, w, h);
    return _laplacianVariance(
        _boxDownsample(luma, w, factor, dw, dh), dw, dh);
  }

  /// Averages each factor x factor block down to one pixel. Averaging rather
  /// than dropping samples, so the result carries the blur of the original
  /// instead of the aliasing of a nearest-neighbour pick.
  static Uint8List _boxDownsample(
    Uint8List src,
    int w,
    int factor,
    int dw,
    int dh,
  ) {
    final out = Uint8List(dw * dh);
    final area = factor * factor;
    for (var y = 0; y < dh; y++) {
      final srcY = y * factor;
      for (var x = 0; x < dw; x++) {
        final srcX = x * factor;
        var sum = 0;
        for (var j = 0; j < factor; j++) {
          final row = (srcY + j) * w + srcX;
          for (var i = 0; i < factor; i++) {
            sum += src[row + i];
          }
        }
        out[y * dw + x] = sum ~/ area;
      }
    }
    return out;
  }

  static double _laplacianVariance(Uint8List luma, int w, int h) {
    if (w < 3 || h < 3) return 0;
    var sum = 0.0;
    var sumSquares = 0.0;
    var count = 0;
    for (var y = 1; y < h - 1; y++) {
      final row = y * w;
      for (var x = 1; x < w - 1; x++) {
        final i = row + x;
        final l =
            4 * luma[i] - luma[i - 1] - luma[i + 1] - luma[i - w] - luma[i + w];
        sum += l;
        sumSquares += l * l;
        count++;
      }
    }
    if (count == 0) return 0;
    final mean = sum / count;
    return (sumSquares / count) - (mean * mean);
  }

  // ── Step 1: cubic upscale ────────────────────────────────────────────────

  /// Upscales a luma buffer by an integer [scale] using a Catmull-Rom cubic,
  /// separably.
  ///
  /// Because [scale] is a whole number, a destination pixel only ever falls at
  /// one of [scale] positions between two source pixels, so the four filter
  /// weights are computed once per phase and reused down the whole buffer.
  static Uint8List _upscaleCubic(Uint8List src, int w, int h, int scale) {
    if (scale <= 1) return src;
    final dw = w * scale;
    final dh = h * scale;

    final offsets = Int32List(scale);
    final weights = List<Float32List>.filled(scale, Float32List(0));
    for (var phase = 0; phase < scale; phase++) {
      // Centre the destination sample inside its source pixel, so the image
      // does not drift by half a pixel as it grows.
      final u = (phase + 0.5) / scale - 0.5;
      final base = u.floor();
      final t = u - base;
      offsets[phase] = base;
      final t2 = t * t;
      final t3 = t2 * t;
      weights[phase] = Float32List.fromList(<double>[
        -0.5 * t3 + t2 - 0.5 * t,
        1.5 * t3 - 2.5 * t2 + 1.0,
        -1.5 * t3 + 2.0 * t2 + 0.5 * t,
        0.5 * t3 - 0.5 * t2,
      ]);
    }

    // Horizontal pass, into a buffer that is already the destination width.
    final wide = Uint8List(dw * h);
    for (var y = 0; y < h; y++) {
      final srcRow = y * w;
      final dstRow = y * dw;
      for (var x = 0; x < dw; x++) {
        final phase = x % scale;
        final base = (x ~/ scale) + offsets[phase];
        final k = weights[phase];
        final v = k[0] * src[srcRow + (base - 1).clamp(0, w - 1)] +
            k[1] * src[srcRow + base.clamp(0, w - 1)] +
            k[2] * src[srcRow + (base + 1).clamp(0, w - 1)] +
            k[3] * src[srcRow + (base + 2).clamp(0, w - 1)];
        wide[dstRow + x] = v < 0 ? 0 : (v > 255 ? 255 : v.round());
      }
    }

    // Vertical pass.
    final out = Uint8List(dw * dh);
    for (var y = 0; y < dh; y++) {
      final phase = y % scale;
      final base = (y ~/ scale) + offsets[phase];
      final k = weights[phase];
      final r0 = (base - 1).clamp(0, h - 1) * dw;
      final r1 = base.clamp(0, h - 1) * dw;
      final r2 = (base + 1).clamp(0, h - 1) * dw;
      final r3 = (base + 2).clamp(0, h - 1) * dw;
      final dstRow = y * dw;
      for (var x = 0; x < dw; x++) {
        final v = k[0] * wide[r0 + x] +
            k[1] * wide[r1 + x] +
            k[2] * wide[r2 + x] +
            k[3] * wide[r3 + x];
        out[dstRow + x] = v < 0 ? 0 : (v > 255 ? 255 : v.round());
      }
    }
    return out;
  }

  // ── Step 3: local contrast stretch ───────────────────────────────────────

  static Uint8List _localContrastStretch(
    Uint8List src,
    int w,
    int h,
    int grid,
    int lowPercentile,
    int highPercentile,
    int globalSpread,
  ) {
    if (grid < 1 || w == 0 || h == 0) return src;
    final tileW = math.max(1, (w / grid).ceil());
    final tileH = math.max(1, (h / grid).ceil());

    // One 256-entry lookup table per tile, so the per-pixel loop below costs
    // four array reads instead of four divisions.
    final luts = List<Uint8List>.filled(grid * grid, Uint8List(0));
    final histogram = Int32List(256);
    for (var ty = 0; ty < grid; ty++) {
      for (var tx = 0; tx < grid; tx++) {
        histogram.fillRange(0, 256, 0);
        final x0 = tx * tileW;
        final y0 = ty * tileH;
        final x1 = math.min(x0 + tileW, w);
        final y1 = math.min(y0 + tileH, h);
        var count = 0;
        for (var y = y0; y < y1; y++) {
          final row = y * w;
          for (var x = x0; x < x1; x++) {
            histogram[src[row + x]]++;
            count++;
          }
        }

        var low = _percentile(histogram, count, lowPercentile);
        var high = _percentile(histogram, count, highPercentile);
        // A tile with no text in it carries only paper and noise. Stretching
        // it would expand that noise across the full range and turn blank
        // board black, so leave it alone. The floor is a fraction of the whole
        // crop's range rather than a fixed number of levels, because a crop
        // that is legitimately low contrast end to end still has to work.
        if (count == 0 ||
            high <= low ||
            (high - low) < globalSpread * kTileSpreadFloorFraction) {
          low = 0;
          high = 255;
        }

        final lut = Uint8List(256);
        final range = high - low;
        for (var v = 0; v < 256; v++) {
          lut[v] = range <= 0 ? v : (((v - low) * 255) ~/ range).clamp(0, 255);
        }
        luts[ty * grid + tx] = lut;
      }
    }

    // Bilinearly interpolate the four nearest tile mappings per pixel. This is
    // what prevents visible tile blocking; without it the grid shows up as
    // hard seams running straight through the characters.
    final tx0s = Int32List(w);
    final tx1s = Int32List(w);
    final fxs = Float32List(w);
    for (var x = 0; x < w; x++) {
      final gx = x / tileW - 0.5;
      final base = gx.floor();
      fxs[x] = gx - base;
      tx0s[x] = base.clamp(0, grid - 1);
      tx1s[x] = (base + 1).clamp(0, grid - 1);
    }

    final out = Uint8List(w * h);
    for (var y = 0; y < h; y++) {
      final gy = y / tileH - 0.5;
      final baseY = gy.floor();
      final fy = gy - baseY;
      final ty0 = baseY.clamp(0, grid - 1);
      final ty1 = (baseY + 1).clamp(0, grid - 1);
      final rowTop = ty0 * grid;
      final rowBottom = ty1 * grid;
      final row = y * w;
      for (var x = 0; x < w; x++) {
        final v = src[row + x];
        final fx = fxs[x];
        final tx0 = tx0s[x];
        final tx1 = tx1s[x];
        final v00 = luts[rowTop + tx0][v].toDouble();
        final v10 = luts[rowTop + tx1][v].toDouble();
        final v01 = luts[rowBottom + tx0][v].toDouble();
        final v11 = luts[rowBottom + tx1][v].toDouble();
        final top = v00 + (v10 - v00) * fx;
        final bottom = v01 + (v11 - v01) * fx;
        out[row + x] = (top + (bottom - top) * fy).round().clamp(0, 255);
      }
    }
    return out;
  }

  // ── Step 4: dot merge (morphological close on the dark foreground) ───────

  /// Dark text on a light ground, so the dark strokes are closed with a min
  /// filter followed by a max filter — equivalently, invert, dilate, erode,
  /// invert. Both filters are separable over a square element, so this runs as
  /// four O(n·k) passes rather than one O(n·k²) one.
  static Uint8List _close(Uint8List src, int w, int h, int kernel) {
    final r = kernel ~/ 2;
    if (r < 1) return src;
    var buf = _rank(src, w, h, r, horizontal: true, takeMin: true);
    buf = _rank(buf, w, h, r, horizontal: false, takeMin: true);
    buf = _rank(buf, w, h, r, horizontal: true, takeMin: false);
    buf = _rank(buf, w, h, r, horizontal: false, takeMin: false);
    return buf;
  }

  static Uint8List _rank(
    Uint8List src,
    int w,
    int h,
    int r, {
    required bool horizontal,
    required bool takeMin,
  }) {
    final out = Uint8List(w * h);
    if (horizontal) {
      for (var y = 0; y < h; y++) {
        final row = y * w;
        for (var x = 0; x < w; x++) {
          final from = x - r < 0 ? 0 : x - r;
          final to = x + r >= w ? w - 1 : x + r;
          var best = src[row + from];
          for (var i = from + 1; i <= to; i++) {
            final v = src[row + i];
            if (takeMin ? v < best : v > best) best = v;
          }
          out[row + x] = best;
        }
      }
    } else {
      for (var x = 0; x < w; x++) {
        for (var y = 0; y < h; y++) {
          final from = y - r < 0 ? 0 : y - r;
          final to = y + r >= h ? h - 1 : y + r;
          var best = src[from * w + x];
          for (var i = from + 1; i <= to; i++) {
            final v = src[i * w + x];
            if (takeMin ? v < best : v > best) best = v;
          }
          out[y * w + x] = best;
        }
      }
    }
    return out;
  }

  // ── Step 5: unsharp mask ─────────────────────────────────────────────────

  static Uint8List _unsharp(Uint8List src, int w, int h, double amount) {
    var blurred = _boxBlur(src, w, h, kUnsharpBlurRadius);
    blurred = _boxBlur(blurred, w, h, kUnsharpBlurRadius);
    final out = Uint8List(w * h);
    for (var i = 0; i < out.length; i++) {
      final v = amount * src[i] - (amount - 1) * blurred[i];
      out[i] = v < 0 ? 0 : (v > 255 ? 255 : v.round());
    }
    return out;
  }

  static Uint8List _boxBlur(Uint8List src, int w, int h, int r) {
    if (r < 1 || w == 0 || h == 0) return src;
    final window = 2 * r + 1;
    final tmp = Uint8List(w * h);

    for (var y = 0; y < h; y++) {
      final row = y * w;
      var sum = 0;
      for (var i = -r; i <= r; i++) {
        sum += src[row + i.clamp(0, w - 1)];
      }
      for (var x = 0; x < w; x++) {
        tmp[row + x] = sum ~/ window;
        final leaving = (x - r).clamp(0, w - 1);
        final entering = (x + r + 1).clamp(0, w - 1);
        sum += src[row + entering] - src[row + leaving];
      }
    }

    final out = Uint8List(w * h);
    for (var x = 0; x < w; x++) {
      var sum = 0;
      for (var i = -r; i <= r; i++) {
        sum += tmp[i.clamp(0, h - 1) * w + x];
      }
      for (var y = 0; y < h; y++) {
        out[y * w + x] = sum ~/ window;
        final leaving = (y - r).clamp(0, h - 1);
        final entering = (y + r + 1).clamp(0, h - 1);
        sum += tmp[entering * w + x] - tmp[leaving * w + x];
      }
    }
    return out;
  }
}

class _LumaScan {
  final Uint8List luma;
  final int width;
  final int height;
  final Int32List histogram;
  final int blownCount;

  const _LumaScan(
    this.luma,
    this.width,
    this.height,
    this.histogram,
    this.blownCount,
  );
}
