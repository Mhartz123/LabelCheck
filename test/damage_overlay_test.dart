import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:ui_prototype/models/scan_record.dart';
import 'package:ui_prototype/widgets/damage_overlay.dart';

/// The overlay sizes itself from the photo's own aspect ratio, which means it
/// depends on the constraints its parent hands it — the kind of thing that
/// analyses clean and then throws on a real screen. These tests render it
/// against genuine JPEGs, in both orientations, to catch that.
void main() {
  late Directory tmp;
  late File landscape;
  late File portrait;

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('damage_overlay_test');
    landscape = File('${tmp.path}/landscape.jpg')
      ..writeAsBytesSync(img.encodeJpg(img.Image(width: 400, height: 225)));
    portrait = File('${tmp.path}/portrait.jpg')
      ..writeAsBytesSync(img.encodeJpg(img.Image(width: 225, height: 400)));
  });

  tearDownAll(() => tmp.deleteSync(recursive: true));

  const dents = [
    DamageDetection(
      label: 'Dent',
      confidence: 0.87,
      left: 0.3,
      top: 0.65,
      width: 0.22,
      height: 0.12,
      sourceIndex: 0,
    ),
  ];

  /// Pumps [child] under the constraints both screens impose: a bounded
  /// width inside a scrolling column, with height free.
  ///
  /// Image decoding is real async I/O, which the fake test clock will not
  /// advance through — so the pump runs inside [WidgetTester.runAsync] and
  /// waits on [precacheImage] for every photo. Without that the overlay never
  /// learns its aspect ratio, silently renders the plain photo, and the test
  /// passes while asserting nothing.
  Future<void> pumpIn(
      WidgetTester tester,
      Widget child, {
        List<File> awaitImages = const [],
      }) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(children: [SizedBox(width: 300, child: child)]),
            ),
          ),
        ),
      );
      for (final file in awaitImages) {
        await precacheImage(FileImage(file), tester.element(find.byType(Scaffold)));
      }
    });
    await tester.pump();
  }

  testWidgets('draws boxes over a landscape photo without overflowing',
          (tester) async {
        await pumpIn(
          tester,
          DamageOverlay(photo: landscape, detections: dents),
          awaitImages: [landscape],
        );

        expect(tester.takeException(), isNull);

        // Prove the image actually resolved and the box-drawing path ran,
        // rather than the widget quietly falling back to the plain photo:
        // the AspectRatio must match the 400x225 source.
        final aspect = tester.widget<AspectRatio>(find.byType(AspectRatio));
        expect(aspect.aspectRatio, closeTo(400 / 225, 1e-6));
        expect(find.byType(CustomPaint), findsWidgets);
      });

  testWidgets('handles a portrait photo too', (tester) async {
    await pumpIn(
      tester,
      DamageOverlay(photo: portrait, detections: dents),
      awaitImages: [portrait],
    );

    expect(tester.takeException(), isNull);
    final aspect = tester.widget<AspectRatio>(find.byType(AspectRatio));
    expect(aspect.aspectRatio, closeTo(225 / 400, 1e-6));
  });

  testWidgets('a photo with no detections still renders', (tester) async {
    await pumpIn(
      tester,
      DamageOverlay(photo: landscape, detections: const []),
      awaitImages: [landscape],
    );

    expect(tester.takeException(), isNull);
    // Nothing to draw means no aspect-ratio wrapper and no painter.
    expect(find.byType(AspectRatio), findsNothing);
  });

  group('DamageEvidence', () {
    testWidgets('renders nothing when the record carries no geometry',
            (tester) async {
          // Records saved before boxes existed: damaged, but nothing to draw.
          await pumpIn(
            tester,
            DamageEvidence(
              photos: [landscape],
              detections: const [],
              foreground: Colors.red,
            ),
          );

          expect(find.textContaining('Where the damage'), findsNothing);
          expect(tester.takeException(), isNull);
        });

    testWidgets('renders nothing when the photos are missing', (tester) async {
      // The results screen for a label-only scan passes no photos.
      await pumpIn(
        tester,
        const DamageEvidence(
          photos: [],
          detections: dents,
          foreground: Colors.red,
        ),
      );

      expect(find.textContaining('Where the damage'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('ignores a detection pointing past the end of the photo list',
            (tester) async {
          // A record whose photos were partly deleted must not throw a range
          // error on the records screen.
          await pumpIn(
            tester,
            const DamageEvidence(
              photos: [],
              detections: [
                DamageDetection(
                  label: 'Dent',
                  confidence: 0.5,
                  left: 0,
                  top: 0,
                  width: 0.1,
                  height: 0.1,
                  sourceIndex: 7,
                ),
              ],
              foreground: Colors.red,
            ),
          );

          expect(tester.takeException(), isNull);
        });

    testWidgets('titles the block with the photo count', (tester) async {
      await pumpIn(
          tester,
          DamageEvidence(
            photos: [landscape, portrait],
            detections: const [
              DamageDetection(
                label: 'Dent',
                confidence: 0.9,
                left: 0.1,
                top: 0.1,
                width: 0.2,
                height: 0.2,
                sourceIndex: 0,
              ),
              DamageDetection(
                label: 'Scratches',
                confidence: 0.7,
                left: 0.4,
                top: 0.4,
                width: 0.2,
                height: 0.2,
                sourceIndex: 1,
              ),
            ],
            foreground: Colors.red,
          ),
          awaitImages: [landscape, portrait],
      );

      expect(find.text('Where the damage was found (2 photos)'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
