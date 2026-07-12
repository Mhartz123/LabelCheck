import 'package:flutter_test/flutter_test.dart';
import 'package:ui_prototype/services/bert_tokenizer.dart';

/// Golden values generated from the project's own tokenizer.json via
/// Python's `tokenizers` library (Tokenizer.from_file(...).encode(text)),
/// to confirm the Dart re-implementation matches HuggingFace's output
/// byte-for-byte for representative label text.
void main() {
  late BertTokenizer tokenizer;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tokenizer = await BertTokenizer.loadFromAsset();
  });

  test('simple product name', () {
    final out = tokenizer.encode('Pedzinc Multivitamins Syrup');
    expect(
      out.inputIds.sublist(0, 10),
      [101, 21877, 2094, 17168, 2278, 4800, 28403, 21266, 23353, 102],
    );
    expect(out.attentionMask.reduce((a, b) => a + b), 10);
    expect(out.inputIds.length, 256);
  });

  test('banned-style phrase with punctuation', () {
    final out = tokenizer.encode('SLIM FIT TEA burns fat fast!!! Not FDA approved.');
    expect(
      out.inputIds.sublist(0, 15),
      [101, 11754, 4906, 5572, 7641, 6638, 3435, 999, 999, 999, 2025, 17473, 4844, 1012, 102],
    );
    expect(out.attentionMask.reduce((a, b) => a + b), 15);
  });

  test('whitespace normalization', () {
    final out = tokenizer.encode('  Weird   whitespace\t\nand\r\nnewlines  ');
    expect(
      out.inputIds.sublist(0, 8),
      [101, 6881, 12461, 15327, 1998, 2047, 12735, 102],
    );
    expect(out.attentionMask.reduce((a, b) => a + b), 8);
  });

  test('accent stripping', () {
    expect(tokenizer.encode('café').inputIds.sublist(0, 3), [101, 7668, 102]);
    expect(tokenizer.encode('naïve').inputIds.sublist(0, 3), [101, 15743, 102]);
    expect(
      tokenizer.encode('garçon').inputIds.sublist(0, 4),
      [101, 11721, 29566, 2078],
    );
  });

  test('oversized single token falls back to UNK', () {
    final out = tokenizer.encode('A' * 2000);
    expect(out.inputIds.sublist(0, 3), [101, 100, 102]);
    expect(out.attentionMask.reduce((a, b) => a + b), 3);
  });

  test('truncates to exactly 256 tokens including CLS/SEP', () {
    final out = tokenizer.encode('good product ' * 300);
    expect(out.inputIds.length, 256);
    expect(out.inputIds[253], 2204); // 'good'
    expect(out.inputIds[254], 4031); // 'product'
    expect(out.inputIds[255], 102); // [SEP]
    expect(out.attentionMask.reduce((a, b) => a + b), 256);
  });

  test('real FDA-advisory-style product name', () {
    final out = tokenizer.encode(
        'MIRACLE WHITE Advance Whitening Capsules');
    expect(
      out.inputIds.sublist(0, 9),
      [101, 9727, 2317, 5083, 2317, 5582, 18269, 2015, 102],
    );
    expect(out.attentionMask.reduce((a, b) => a + b), 9);
  });
}
