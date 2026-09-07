import 'package:flutter_test/flutter_test.dart';
import 'package:ui_prototype/models/scan_record.dart';

/// Damage boxes are the one part of a scan that has to survive two very
/// different journeys: into data.json and back for a saved record, and
/// straight into the results screen for a scan that hasn't been saved yet.
/// Both draw from normalised coordinates, so the fractions and the
/// sourceIndex that ties a box to its photo have to round-trip exactly — a
/// dropped sourceIndex silently paints the dent on the wrong side of the box.
void main() {
  group('DamageDetection', () {
    const box = DamageDetection(
      label: 'Dent',
      confidence: 0.8734,
      left: 0.25,
      top: 0.1,
      width: 0.3,
      height: 0.45,
      sourceIndex: 2,
    );

    test('round-trips every field through JSON', () {
      final restored = DamageDetection.fromJson(box.toJson());

      expect(restored.label, 'Dent');
      expect(restored.confidence, closeTo(0.8734, 1e-9));
      expect(restored.left, 0.25);
      expect(restored.top, 0.1);
      expect(restored.width, 0.3);
      expect(restored.height, 0.45);
      expect(restored.sourceIndex, 2);
    });

    test('right and bottom derive from the origin plus the extent', () {
      expect(box.right, closeTo(0.55, 1e-9));
      expect(box.bottom, closeTo(0.55, 1e-9));
    });

    test('confidence renders as a whole percentage', () {
      expect(box.confidenceLabel, '87%');
    });

    test('a malformed entry falls back rather than throwing', () {
      // A record hand-edited or written by an older build must not crash the
      // records screen — it should degrade to a harmless zero-size box.
      final restored = DamageDetection.fromJson(const {});
      expect(restored.label, 'Damage');
      expect(restored.confidence, 0.0);
      expect(restored.width, 0.0);
      expect(restored.sourceIndex, 0);
    });
  });

  group('DamageCheckResult geometry', () {
    const boxes = [
      DamageDetection(
        label: 'Dent',
        confidence: 0.91,
        left: 0.1,
        top: 0.1,
        width: 0.2,
        height: 0.2,
        sourceIndex: 0,
      ),
      DamageDetection(
        label: 'Dent',
        confidence: 0.62,
        left: 0.5,
        top: 0.5,
        width: 0.1,
        height: 0.1,
        sourceIndex: 1,
      ),
      DamageDetection(
        label: 'Scratches',
        confidence: 0.72,
        left: 0.3,
        top: 0.2,
        width: 0.2,
        height: 0.1,
        sourceIndex: 1,
      ),
    ];

    test('boxes survive a record round-trip with their source photo', () {
      const damage = DamageCheckResult(
        available: true,
        message: 'Possible packaging damage detected: Dent, Scratches.',
        isDamaged: true,
        detections: ['Dent', 'Dent', 'Scratches'],
        boxes: boxes,
        maxConfidence: 0.91,
      );

      final restored = DamageCheckResult.fromJson(damage.toJson());

      expect(restored.boxes, hasLength(3));
      expect(restored.boxes.map((b) => b.sourceIndex), [0, 1, 1]);
      expect(restored.boxes[2].label, 'Scratches');
      expect(restored.boxes[2].confidence, closeTo(0.72, 1e-9));
      // The plain class list stays in place alongside the geometry, because
      // the dashboard payload and older readers still use it.
      expect(restored.detections, ['Dent', 'Dent', 'Scratches']);
    });

    test('summary groups by class and reports the best confidence', () {
      const damage = DamageCheckResult(
        available: true,
        message: '',
        isDamaged: true,
        detections: ['Dent', 'Dent', 'Scratches'],
        boxes: boxes,
        maxConfidence: 0.91,
      );

      // Two dents collapse to one entry carrying the higher score; a lone
      // scratch just states its own.
      expect(damage.detectionSummary, 'Dent ×2 (up to 91%), Scratches (72%)');
    });

    test('a record saved before boxes existed still summarises its classes',
            () {
          // No 'boxes' key at all — the shape every record written before this
          // feature has on disk.
          final restored = DamageCheckResult.fromJson(const {
            'available': true,
            'message': 'Possible packaging damage detected: Dent.',
            'isDamaged': true,
            'detections': ['Dent', 'Dent'],
            'maxConfidence': 0.55,
          });

          expect(restored.boxes, isEmpty);
          expect(restored.isDamaged, isTrue);
          // Falls back to the deduplicated class list rather than showing
          // nothing or inventing a confidence it never stored.
          expect(restored.detectionSummary, 'Dent');
        });

    test('placeholder and notPerformed carry no boxes', () {
      expect(const DamageCheckResult.placeholder().boxes, isEmpty);
      expect(const DamageCheckResult.notPerformed().boxes, isEmpty);
    });

    test('hasScratch reads the model\'s lower-case class names', () {
      // The YOLOv5nu model's metadata names are 'dents'/'scratches'; the
      // service title-cases them, but the check must not depend on that.
      const damage = DamageCheckResult(
        available: true,
        message: '',
        isDamaged: true,
        detections: ['scratches'],
      );
      expect(damage.hasScratch, isTrue);
    });
  });
}
