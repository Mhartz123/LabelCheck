import 'dart:math' as math;

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import 'ocr_preprocessor.dart' show OcrProfile;

/// How far off horizontal a line may sit and still be treated as part of the
/// label, per capture profile. See the calibration table in the thesis.
const double kDateCodeMaxSkewDegrees = 12;
const double kProductNameMaxSkewDegrees = 15;
const double kIngredientsMaxSkewDegrees = 20;

/// How close to the tallest element on a panel an element has to be, as a
/// fraction of that height, to count as part of the same piece of display type.
const double kLargestElementTolerance = 0.7;

/// Geometric post-processing on ML Kit's output.
///
/// The recognizer is frozen, so what it returns cannot be changed — but it can
/// be filtered, and most of the junk interleaved into a date-code reading is
/// junk by virtue of where it sits rather than what it says.
class OcrGeometry {
  const OcrGeometry._();

  static double maxSkewDegreesFor(OcrProfile profile) => switch (profile) {
        OcrProfile.dateCode => kDateCodeMaxSkewDegrees,
        OcrProfile.productName => kProductNameMaxSkewDegrees,
        OcrProfile.ingredients => kIngredientsMaxSkewDegrees,
      };

  /// Angle of [line] in degrees, measured off its own corner points.
  ///
  /// [TextLine.angle] is deliberately not used: it is nullable and populated
  /// inconsistently across plugin versions, whereas the corner points are
  /// always there. They come back clockwise from the top left, so the top
  /// edge runs from `cornerPoints[0]` to `cornerPoints[1]`.
  static double lineAngleDegrees(TextLine line) {
    final points = line.cornerPoints;
    if (points.length < 2) return 0;
    final topLeft = points[0];
    final topRight = points[1];
    final dx = (topRight.x - topLeft.x).toDouble();
    final dy = (topRight.y - topLeft.y).toDouble();
    if (dx == 0 && dy == 0) return 0;
    return math.atan2(dy, dx) * 180 / math.pi;
  }

  /// Every line in [text] within [maxSkewDegrees] of horizontal.
  ///
  /// This is what removes a tamper seal's arc text and the upside-down address
  /// printed on it, both of which ML Kit happily returns interleaved with the
  /// date line. An upside-down line comes back near 180°, so it fails the same
  /// test as a vertical one.
  static List<TextLine> horizontalLines(
    RecognizedText text, {
    double maxSkewDegrees = kDateCodeMaxSkewDegrees,
  }) {
    final kept = <TextLine>[];
    for (final block in text.blocks) {
      for (final line in block.lines) {
        if (lineAngleDegrees(line).abs() <= maxSkewDegrees) kept.add(line);
      }
    }
    return kept;
  }

  /// The lines of [lines] that carry display type — those holding at least one
  /// element within [tolerance] of the tallest element on the panel — in top to
  /// bottom order.
  ///
  /// This exists because [largestElements] returns a flat bag of elements
  /// gathered across every line, and joining that bag into one string welds
  /// fragments from opposite ends of a panel together: a real MX3 carton came
  /// back as "M MS" and a Medicol carton as "LE NT DNE*", both of them pieces
  /// of unrelated display text concatenated in element order.
  ///
  /// A product name is one or two adjacent lines of large type, not a
  /// scattering of the tallest glyphs, so keeping whole lines and their reading
  /// order preserves the thing the caller is actually looking for.
  static List<TextLine> prominentLines(
    List<TextLine> lines, {
    double tolerance = kLargestElementTolerance,
  }) {
    var tallest = 0.0;
    for (final line in lines) {
      for (final element in line.elements) {
        final height = element.boundingBox.height;
        if (height > tallest) tallest = height;
      }
    }
    if (tallest <= 0) return lines;

    final cutoff = tallest * tolerance;
    final kept = <TextLine>[
      for (final line in lines)
        if (line.elements
            .any((e) => e.boundingBox.height >= cutoff))
          line,
    ];
    // ML Kit's block order is roughly reading order but is not guaranteed to
    // be, and a headline assembled out of order is no better than one
    // assembled out of fragments.
    kept.sort((a, b) => a.boundingBox.top.compareTo(b.boundingBox.top));
    return kept;
  }

  /// The elements of [lines] whose bounding box is within [tolerance] of the
  /// tallest one, in the order given.
  ///
  /// Used to pull the brand name off a front panel. The product name is almost
  /// always the physically largest text on the pack, which is a far stronger
  /// prior than reading order or position — both of which put a regulatory
  /// footnote ahead of the name often enough to matter.
  static List<TextElement> largestElements(
    List<TextLine> lines, {
    double tolerance = kLargestElementTolerance,
  }) {
    final elements = <TextElement>[
      for (final line in lines) ...line.elements,
    ];
    if (elements.isEmpty) return const <TextElement>[];

    var tallest = 0.0;
    for (final element in elements) {
      final height = element.boundingBox.height;
      if (height > tallest) tallest = height;
    }
    if (tallest <= 0) return elements;

    final cutoff = tallest * tolerance;
    return <TextElement>[
      for (final element in elements)
        if (element.boundingBox.height >= cutoff) element,
    ];
  }
}
