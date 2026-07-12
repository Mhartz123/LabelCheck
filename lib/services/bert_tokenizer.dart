import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;

/// Fixed-length tokenizer output ready to feed the DistilBERT ONNX model.
class TokenizedInput {
  final Int32List inputIds;
  final Int32List attentionMask;

  const TokenizedInput(this.inputIds, this.attentionMask);
}

/// Dart re-implementation of HuggingFace's `BertTokenizerFast` (WordPiece),
/// matching this project's `tokenizer.json`: bert-base-uncased vocab,
/// do_lower_case, fixed padding/truncation to 256 tokens.
///
/// Accent stripping only covers Latin-1 Supplement / Latin Extended-A (the
/// accented letters that actually show up on English/Filipino product
/// labels) rather than full Unicode NFD decomposition — anything outside
/// that range falls through to WordPiece as-is, same as upstream does for
/// unmapped characters.
class BertTokenizer {
  static const int padId = 0;
  static const int unkId = 100;
  static const int clsId = 101;
  static const int sepId = 102;
  static const int maxLength = 256;
  static const int maxInputCharsPerWord = 100;
  static const String _unkToken = '[UNK]';

  final Map<String, int> _vocab;

  BertTokenizer._(this._vocab);

  static Future<BertTokenizer> loadFromAsset(
      [String assetPath = 'assets/tokenizer/vocab.json']) async {
    final jsonStr = await rootBundle.loadString(assetPath);
    final Map<String, dynamic> raw =
        json.decode(jsonStr) as Map<String, dynamic>;
    return BertTokenizer._(raw.map((k, v) => MapEntry(k, v as int)));
  }

  /// Encodes [text] to fixed-length [sequenceLength] ids + attention mask.
  /// Defaults to [maxLength] (256) so existing callers are unchanged; the
  /// ONNX semantic matcher passes 64 (ample for short FDA product names).
  TokenizedInput encode(String text, {int? sequenceLength}) {
    final length = sequenceLength ?? maxLength;

    final wordpieceTokens = <String>[];
    for (final basic in _basicTokenize(text)) {
      wordpieceTokens.addAll(_wordpieceTokenize(basic));
    }

    final maxContentTokens = length - 2; // room for [CLS] and [SEP]
    final content = wordpieceTokens.length > maxContentTokens
        ? wordpieceTokens.sublist(0, maxContentTokens)
        : wordpieceTokens;

    final ids = Int32List(length);
    final attn = Int32List(length);
    ids[0] = clsId;
    attn[0] = 1;

    var i = 1;
    for (final tok in content) {
      ids[i] = _vocab[tok] ?? unkId;
      attn[i] = 1;
      i++;
    }
    ids[i] = sepId;
    attn[i] = 1;
    // Remaining slots stay at 0 (pad id 0 / attention 0) — Int32List default.

    return TokenizedInput(ids, attn);
  }

  // ── Basic tokenize: clean text, space out CJK, lowercase + strip accents,
  // split on punctuation ──────────────────────────────────────────────────
  List<String> _basicTokenize(String text) {
    final cleaned = _cleanText(text);
    final spaced = _spaceOutCjk(cleaned);
    final tokens = <String>[];
    for (final word in spaced.split(_whitespaceRegex)) {
      if (word.isEmpty) continue;
      final normalized = _stripAccents(word.toLowerCase());
      tokens.addAll(_splitOnPunctuation(normalized));
    }
    return tokens;
  }

  static final RegExp _whitespaceRegex = RegExp(r'\s+');

  String _cleanText(String text) {
    final buffer = StringBuffer();
    for (final rune in text.runes) {
      if (rune == 0 || rune == 0xFFFD || _isControl(rune)) continue;
      if (_isWhitespace(rune)) {
        buffer.write(' ');
      } else {
        buffer.writeCharCode(rune);
      }
    }
    return buffer.toString();
  }

  bool _isControl(int rune) {
    if (rune == 9 || rune == 10 || rune == 13) return false;
    return (rune >= 0x00 && rune <= 0x1F) || rune == 0x7F;
  }

  bool _isWhitespace(int rune) {
    if (rune == 9 || rune == 10 || rune == 13 || rune == 32) return true;
    return rune == 0xA0 ||
        (rune >= 0x2000 && rune <= 0x200A) ||
        rune == 0x202F ||
        rune == 0x205F ||
        rune == 0x3000;
  }

  String _spaceOutCjk(String text) {
    final buffer = StringBuffer();
    for (final rune in text.runes) {
      if (_isCjk(rune)) {
        buffer
          ..write(' ')
          ..writeCharCode(rune)
          ..write(' ');
      } else {
        buffer.writeCharCode(rune);
      }
    }
    return buffer.toString();
  }

  bool _isCjk(int cp) {
    return (cp >= 0x4E00 && cp <= 0x9FFF) ||
        (cp >= 0x3400 && cp <= 0x4DBF) ||
        (cp >= 0x20000 && cp <= 0x2A6DF) ||
        (cp >= 0x2A700 && cp <= 0x2EBEF) ||
        (cp >= 0xF900 && cp <= 0xFAFF) ||
        (cp >= 0x2F800 && cp <= 0x2FA1F);
  }

  String _stripAccents(String text) {
    final buffer = StringBuffer();
    for (final rune in text.runes) {
      final mapped = _accentMap[rune];
      if (mapped != null) {
        buffer.write(mapped);
      } else {
        buffer.writeCharCode(rune);
      }
    }
    return buffer.toString();
  }

  List<String> _splitOnPunctuation(String token) {
    final result = <String>[];
    var current = StringBuffer();
    for (final rune in token.runes) {
      if (_isAsciiPunctuation(rune)) {
        if (current.isNotEmpty) {
          result.add(current.toString());
          current = StringBuffer();
        }
        result.add(String.fromCharCode(rune));
      } else {
        current.writeCharCode(rune);
      }
    }
    if (current.isNotEmpty) result.add(current.toString());
    return result;
  }

  bool _isAsciiPunctuation(int cp) {
    return (cp >= 33 && cp <= 47) ||
        (cp >= 58 && cp <= 64) ||
        (cp >= 91 && cp <= 96) ||
        (cp >= 123 && cp <= 126);
  }

  List<String> _wordpieceTokenize(String token) {
    final chars = token.runes.toList();
    if (chars.length > maxInputCharsPerWord) {
      return const [_unkToken];
    }

    final output = <String>[];
    var start = 0;
    while (start < chars.length) {
      var end = chars.length;
      String? matched;
      while (start < end) {
        var substr = String.fromCharCodes(chars.sublist(start, end));
        if (start > 0) substr = '##$substr';
        if (_vocab.containsKey(substr)) {
          matched = substr;
          break;
        }
        end--;
      }
      if (matched == null) {
        return const [_unkToken];
      }
      output.add(matched);
      start = end;
    }
    return output;
  }

  // Maps accented Latin-1 Supplement / Latin Extended-A letters to their
  // unaccented ASCII form (NFD decomposition with combining marks removed).
  static const Map<int, String> _accentMap = {
    0x00C0: 'A', 0x00C1: 'A', 0x00C2: 'A', 0x00C3: 'A', 0x00C4: 'A',
    0x00C5: 'A', 0x00C7: 'C', 0x00C8: 'E', 0x00C9: 'E', 0x00CA: 'E',
    0x00CB: 'E', 0x00CC: 'I', 0x00CD: 'I', 0x00CE: 'I', 0x00CF: 'I',
    0x00D1: 'N', 0x00D2: 'O', 0x00D3: 'O', 0x00D4: 'O', 0x00D5: 'O',
    0x00D6: 'O', 0x00D9: 'U', 0x00DA: 'U', 0x00DB: 'U', 0x00DC: 'U',
    0x00DD: 'Y',
    0x00E0: 'a', 0x00E1: 'a', 0x00E2: 'a', 0x00E3: 'a', 0x00E4: 'a',
    0x00E5: 'a', 0x00E7: 'c', 0x00E8: 'e', 0x00E9: 'e', 0x00EA: 'e',
    0x00EB: 'e', 0x00EC: 'i', 0x00ED: 'i', 0x00EE: 'i', 0x00EF: 'i',
    0x00F1: 'n', 0x00F2: 'o', 0x00F3: 'o', 0x00F4: 'o', 0x00F5: 'o',
    0x00F6: 'o', 0x00F9: 'u', 0x00FA: 'u', 0x00FB: 'u', 0x00FC: 'u',
    0x00FD: 'y', 0x00FF: 'y',
    0x0100: 'A', 0x0101: 'a', 0x0102: 'A', 0x0103: 'a', 0x0104: 'A',
    0x0105: 'a', 0x0106: 'C', 0x0107: 'c', 0x0108: 'C', 0x0109: 'c',
    0x010A: 'C', 0x010B: 'c', 0x010C: 'C', 0x010D: 'c', 0x010E: 'D',
    0x010F: 'd', 0x0112: 'E', 0x0113: 'e', 0x0114: 'E', 0x0115: 'e',
    0x0116: 'E', 0x0117: 'e', 0x0118: 'E', 0x0119: 'e', 0x011A: 'E',
    0x011B: 'e', 0x011C: 'G', 0x011D: 'g', 0x011E: 'G', 0x011F: 'g',
    0x0120: 'G', 0x0121: 'g', 0x0122: 'G', 0x0123: 'g', 0x0124: 'H',
    0x0125: 'h', 0x0128: 'I', 0x0129: 'i', 0x012A: 'I', 0x012B: 'i',
    0x012C: 'I', 0x012D: 'i', 0x012E: 'I', 0x012F: 'i', 0x0130: 'I',
    0x0134: 'J', 0x0135: 'j', 0x0136: 'K', 0x0137: 'k', 0x0139: 'L',
    0x013A: 'l', 0x013B: 'L', 0x013C: 'l', 0x013D: 'L', 0x013E: 'l',
    0x0143: 'N', 0x0144: 'n', 0x0145: 'N', 0x0146: 'n', 0x0147: 'N',
    0x0148: 'n', 0x014C: 'O', 0x014D: 'o', 0x014E: 'O', 0x014F: 'o',
    0x0150: 'O', 0x0151: 'o', 0x0154: 'R', 0x0155: 'r', 0x0156: 'R',
    0x0157: 'r', 0x0158: 'R', 0x0159: 'r', 0x015A: 'S', 0x015B: 's',
    0x015C: 'S', 0x015D: 's', 0x015E: 'S', 0x015F: 's', 0x0160: 'S',
    0x0161: 's', 0x0162: 'T', 0x0163: 't', 0x0164: 'T', 0x0165: 't',
    0x0168: 'U', 0x0169: 'u', 0x016A: 'U', 0x016B: 'u', 0x016C: 'U',
    0x016D: 'u', 0x016E: 'U', 0x016F: 'u', 0x0170: 'U', 0x0171: 'u',
    0x0172: 'U', 0x0173: 'u', 0x0174: 'W', 0x0175: 'w', 0x0176: 'Y',
    0x0177: 'y', 0x0178: 'Y', 0x0179: 'Z', 0x017A: 'z', 0x017B: 'Z',
    0x017C: 'z', 0x017D: 'Z', 0x017E: 'z',
  };
}
