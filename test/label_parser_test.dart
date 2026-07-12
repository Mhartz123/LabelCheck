import 'package:flutter_test/flutter_test.dart';
import 'package:ui_prototype/services/label_parser.dart';

void main() {
  group('parseExpiry', () {
    test('YYYY-MM resolves to the last day of that month', () {
      expect(LabelParser.parseExpiry('EXP 2099-12'), DateTime(2099, 12, 31));
      expect(LabelParser.parseExpiry('2099-02'), DateTime(2099, 2, 28));
    });

    test('full YYYY-MM-DD date', () {
      expect(LabelParser.parseExpiry('Expiry: 2020-01-15'),
          DateTime(2020, 1, 15));
    });

    test('MM/YYYY resolves to end of month', () {
      expect(LabelParser.parseExpiry('03/2099'), DateTime(2099, 3, 31));
    });

    test('DD/MM/YYYY with an out-of-range day is unambiguous', () {
      expect(LabelParser.parseExpiry('25/12/2099'), DateTime(2099, 12, 25));
    });

    test('ambiguous D/M/YYYY assumes day-first', () {
      expect(LabelParser.parseExpiry('07/08/2099'), DateTime(2099, 8, 7));
    });

    test('invalid month yields null', () {
      expect(LabelParser.parseExpiry('2099/13/01'), isNull);
    });

    test('no date / empty yields null (→ re-scan upstream)', () {
      expect(LabelParser.parseExpiry('best before soon'), isNull);
      expect(LabelParser.parseExpiry(''), isNull);
    });
  });

  group('ingredientsPresent', () {
    test('real ingredient text counts as present', () {
      expect(LabelParser.ingredientsPresent('Sugar, Salt, Water'), isTrue);
      expect(
          LabelParser.ingredientsPresent('Ingredients: Milk, Soy'), isTrue);
    });

    test('empty or noise-only text is not present', () {
      expect(LabelParser.ingredientsPresent(''), isFalse);
      expect(LabelParser.ingredientsPresent('--- .. ,,'), isFalse);
      expect(LabelParser.ingredientsPresent('a b c'), isFalse); // < 8 letters
    });
  });
}
