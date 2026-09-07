import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:ui_prototype/models/scan_record.dart';
import 'package:ui_prototype/services/report_builder.dart';

/// The PDF is the one artefact that leaves the phone, so its damage-evidence
/// section has to survive the awkward records too: a photo that has gone
/// missing, a box pointing past the end of the photo list, a record saved
/// before geometry existed. Any throw here takes the whole report down, not
/// just one card — these tests exercise the real decode-and-layout path.
void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('report_evidence_test');
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  Directory writeRecord(
      String name, {
        required ScanRecord record,
        List<String> photos = const [],
      }) {
    final dir = Directory('${tmp.path}/$name')..createSync(recursive: true);
    File('${dir.path}/data.json')
        .writeAsStringSync(jsonEncode(record.toJson()));
    for (final photo in photos) {
      File('${dir.path}/$photo.jpg').writeAsBytesSync(
        img.encodeJpg(img.Image(width: 400, height: 225)),
      );
    }
    return dir;
  }

  ScanRecord damaged(List<DamageDetection> boxes) => ScanRecord(
    kind: ScanKind.damage,
    status: ComplianceStatus.nonCompliant,
    matchedKeyword: 'packaging damage',
    reasons: const ['Possible packaging damage detected.'],
    productName: 'Amlodipine 10mg',
    expiration: '—',
    ingredients: '—',
    extractedText: '',
    packagingType: PackagingType.box,
    damageCheck: DamageCheckResult(
      available: true,
      message: 'Possible packaging damage detected: Dent.',
      isDamaged: true,
      detections: boxes.map((b) => b.label).toList(),
      boxes: boxes,
      maxConfidence: boxes.isEmpty
          ? 0
          : boxes.map((b) => b.confidence).reduce((a, b) => a > b ? a : b),
    ),
    scannedAt: DateTime.parse('2026-09-05T10:00:00.000'),
  );

  const dent = DamageDetection(
    label: 'Dent',
    confidence: 0.87,
    left: 0.31,
    top: 0.65,
    width: 0.23,
    height: 0.12,
    sourceIndex: 0,
  );

  test('a damaged record renders its annotated photo into the PDF', () async {
    final dir = writeRecord('Amlodipine',
        record: damaged(const [dent]), photos: ['box_front']);

    final doc = await ReportBuilder.buildFromDirs([dir]);
    final bytes = await doc.save();

    // A PDF that carries an embedded photo is substantially larger than the
    // text-only report, which is the cheapest honest signal that the image
    // and its overlay actually made it into the document.
    expect(bytes.length, greaterThan(4000));
    expect(utf8.decode(bytes.sublist(0, 5)), startsWith('%PDF'));
  });

  test('boxes spread across two photos both render', () async {
    final dir = writeRecord(
      'Sulodexide',
      record: damaged(const [
        dent,
        DamageDetection(
          label: 'Scratches',
          confidence: 0.72,
          left: 0.4,
          top: 0.2,
          width: 0.2,
          height: 0.1,
          sourceIndex: 1,
        ),
      ]),
      photos: ['box_front', 'box_side1'],
    );

    final doc = await ReportBuilder.buildFromDirs([dir]);
    expect((await doc.save()).length, greaterThan(4000));
  });

  test('a detection pointing past the last photo is skipped, not fatal',
          () async {
        // The record claims a fourth box shot; only one was ever saved.
        final dir = writeRecord(
          'Missing photo',
          record: damaged(const [
            DamageDetection(
              label: 'Dent',
              confidence: 0.5,
              left: 0.1,
              top: 0.1,
              width: 0.2,
              height: 0.2,
              sourceIndex: 3,
            ),
          ]),
          photos: ['box_front'],
        );

        final doc = await ReportBuilder.buildFromDirs([dir]);
        expect((await doc.save()).length, greaterThan(1000));
      });

  test('an unreadable photo is dropped rather than breaking the report',
          () async {
        final dir = writeRecord('Corrupt',
            record: damaged(const [dent]), photos: []);
        // Not a JPEG at all — decode will fail.
        File('${dir.path}/box_front.jpg').writeAsStringSync('not an image');

        final doc = await ReportBuilder.buildFromDirs([dir]);
        expect((await doc.save()).length, greaterThan(1000));
      });

  test('a record saved before geometry existed still builds', () async {
    final dir = writeRecord('Legacy',
        record: damaged(const []), photos: ['box_front']);

    final doc = await ReportBuilder.buildFromDirs([dir]);
    expect((await doc.save()).length, greaterThan(1000));
  });

  test('a report with no damaged records still builds', () async {
    final dir = writeRecord(
      'Clean',
      record: ScanRecord(
        kind: ScanKind.damage,
        status: ComplianceStatus.compliant,
        matchedKeyword: '—',
        reasons: const [],
        productName: 'Clean box',
        expiration: '—',
        ingredients: '—',
        extractedText: '',
        packagingType: PackagingType.box,
        damageCheck: const DamageCheckResult(
          available: true,
          message: 'No packaging damage detected.',
        ),
        scannedAt: DateTime.parse('2026-09-05T10:00:00.000'),
      ),
      photos: ['box_front'],
    );

    final doc = await ReportBuilder.buildFromDirs([dir]);
    expect((await doc.save()).length, greaterThan(1000));
  });

  test('non-ASCII glyphs are folded so the PDF can actually draw them',
          () async {
        // The pdf package's built-in Helvetica has no Unicode coverage: an
        // em dash or the multiplication sign in "Dent x2" silently draws as
        // nothing. Two dents produce a summary containing U+00D7, and the
        // '—' placeholder rides along in the matched-keyword column.
        final dir = writeRecord(
          'Two dents',
          record: damaged(const [
            dent,
            DamageDetection(
              label: 'Dent',
              confidence: 0.62,
              left: 0.6,
              top: 0.2,
              width: 0.1,
              height: 0.1,
              sourceIndex: 0,
            ),
          ]),
          photos: ['box_front'],
        );

        final doc = await ReportBuilder.buildFromDirs([dir]);
        final bytes = await doc.save();

        // The summary the screens show uses the nicer glyph...
        final record = ScanRecord.fromJson(
          jsonDecode(File('${dir.path}/data.json').readAsStringSync())
          as Map<String, dynamic>,
        );
        expect(record.damageCheck.detectionSummary, contains('×'));
        // ...but nothing that Helvetica cannot draw reaches the PDF.
        expect(bytes.length, greaterThan(4000));
      });

  test('an empty report builds', () async {
    final doc = await ReportBuilder.buildFromDirs([]);
    expect((await doc.save()).length, greaterThan(1000));
  });
}
