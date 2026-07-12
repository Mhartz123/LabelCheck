import 'package:flutter_test/flutter_test.dart';
import 'package:ui_prototype/services/fda_dataset_checker.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await FdaDatasetChecker.ensureLoaded();
  });

  test('matches a known advisory product embedded in noisy OCR text', () {
    const ocrText = '''
      MIRACLE WHITE
      Advance Whitening Capsules
      Food Supplement
      Net Wt. 500mg x 30 capsules
    ''';
    final match = FdaDatasetChecker.match(ocrText);
    expect(match, isNotNull);
    expect(match!.advisoryNumber, 'FDA Advisory No. 2020-1618');
    expect(match.category, 'Food Advisories');
  });

  test('does not match ordinary compliant-looking label text', () {
    const ocrText = '''
      Pedzinc Multivitamins Syrup
      FDA Reg. No. DR-XY12345
      Store in a cool dry place. Take as directed.
      Exp. 2027-05
    ''';
    final match = FdaDatasetChecker.match(ocrText);
    expect(match, isNull);
  });

  test('returns null for empty text', () {
    expect(FdaDatasetChecker.match(''), isNull);
  });

  test('fuzzy pass recovers single-character OCR misreads', () {
    // Two words of the known advisory name are garbled by one character each
    // (ADVANCE→ADVANGE, WHITENING→WHITENLNG), dropping exact overlap to 3/5 =
    // 0.6 — below the 0.8 threshold — so only the edit-distance-1 fuzzy pass
    // can still recover the match.
    const misreadOcr = '''
      MIRACLE WHITE
      ADVANGE WHITENLNG CAPSULES
      Food Supplement
    ''';
    final outcome = FdaDatasetChecker.matchOutcome(misreadOcr);
    expect(outcome.match, isNotNull);
    expect(outcome.match!.advisoryNumber, 'FDA Advisory No. 2020-1618');
    expect(outcome.bestRatio, greaterThanOrEqualTo(0.8));
  });

  test('matchOutcome exposes a sub-threshold bestRatio for a clear miss', () {
    final outcome = FdaDatasetChecker.matchOutcome(
        'Totally Unrelated Vitamin C Chewables 500mg');
    expect(outcome.match, isNull);
    expect(outcome.bestRatio, lessThan(0.8));
  });
}
