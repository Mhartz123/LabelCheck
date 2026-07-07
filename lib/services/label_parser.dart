/// Heuristic, best-effort extraction of structured label fields from OCR
/// text. This is an explicit placeholder bridge — it will be replaced by a
/// DistilBERT classifier matched against an FDA product dataset once that
/// model is ready. Keep this file as the single seam for that swap.
class LabelFields {
  final String productName;
  final String brand;
  final String expiration;
  final String ingredients;

  const LabelFields({
    required this.productName,
    required this.brand,
    required this.expiration,
    required this.ingredients,
  });
}

class LabelParser {
  static LabelFields parse(String combinedText) {
    final lines = combinedText
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();

    final productName = _extractProductName(lines);
    return LabelFields(
      productName: productName,
      brand: _extractBrand(lines, productName),
      expiration: _extractExpiration(combinedText),
      ingredients: _extractIngredients(combinedText),
    );
  }

  static final RegExp _noisePrefixes = RegExp(
    r'^(fda|reg\.?\s*no|lot\s*no|batch|exp|mfg|net\s*wt|www\.|http)',
    caseSensitive: false,
  );
  static final RegExp _pureNoise = RegExp(r'^[\d\W]+$');

  static String _extractProductName(List<String> lines) {
    for (final line in lines) {
      if (line.length < 3) continue;
      if (_noisePrefixes.hasMatch(line)) continue;
      if (_pureNoise.hasMatch(line)) continue;
      return line;
    }
    return 'Unknown Product';
  }

  static final RegExp _brandLineRegex =
      RegExp(r'^brand\s*[:\-]\s*(.+)$', caseSensitive: false);

  static String _extractBrand(List<String> lines, String productName) {
    for (final line in lines) {
      final m = _brandLineRegex.firstMatch(line);
      if (m != null) return m.group(1)!.trim();
    }
    for (final line in lines) {
      if (line != productName && line.length >= 3 && line.length <= 40) {
        return line;
      }
    }
    return 'Unknown Brand';
  }

  static final RegExp _expKeywordRegex = RegExp(
    r'(exp(?:iry|iration)?\.?\s*(?:date)?\s*[:\-]?\s*)'
    r'(\d{4}[\/\-\.]\d{1,2}(?:[\/\-\.]\d{1,2})?|\d{1,2}[\/\-\.]\d{4}|\d{1,2}[\/\-\.]\d{1,2}[\/\-\.]\d{2,4})',
    caseSensitive: false,
  );
  static final RegExp _bareDateRegex =
      RegExp(r'\b(\d{4}[\/\-\.]\d{1,2}(?:[\/\-\.]\d{1,2})?)\b');

  static String _extractExpiration(String text) {
    final m = _expKeywordRegex.firstMatch(text);
    if (m != null) return m.group(2)!.trim();

    final bareMatch = _bareDateRegex.firstMatch(text);
    if (bareMatch != null) return bareMatch.group(1)!.trim();

    return 'Not detected';
  }

  static final RegExp _ingredientsStartRegex =
      RegExp(r'ingredients?\s*[:\-]', caseSensitive: false);
  static final RegExp _ingredientsStopRegex = RegExp(
    r'\n\s*(directions?|warnings?|storage|manufactured|distributed|fda\s*reg|lot\s*no|net\s*wt)\b',
    caseSensitive: false,
  );

  static String _extractIngredients(String text) {
    final startMatch = _ingredientsStartRegex.firstMatch(text);
    if (startMatch == null) return 'No ingredient list detected';

    final after = text.substring(startMatch.end).trim();
    final stopMatch = _ingredientsStopRegex.firstMatch(after);
    final cut = stopMatch != null ? after.substring(0, stopMatch.start) : after;

    final cleaned = cut.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.isEmpty) return 'No ingredient list detected';
    return cleaned.length > 500 ? '${cleaned.substring(0, 500)}…' : cleaned;
  }
}
