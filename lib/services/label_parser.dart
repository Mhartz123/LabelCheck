import '../models/scan_record.dart';

/// Structured label fields, extracted per capture slot rather than guessed
/// out of one combined OCR blob — each field's photo is dedicated to that
/// field, so the OCR output for that slot already IS the field (modulo light
/// cleanup below).
class LabelFields {
  final String productName;

  /// Human-readable expiration string for display ("2027-05", "Not detected").
  final String expiration;

  /// Parsed expiration cutoff (last valid day), or null if no date was read.
  /// Month-precision dates ("2027-05") resolve to the last day of that month.
  final DateTime? expirationDate;

  /// Cleaned ingredient-list text for display.
  final String ingredients;

  /// Whether a real ingredient list was detected on the ingredient slot.
  final bool ingredientsPresent;

  const LabelFields({
    required this.productName,
    required this.expiration,
    required this.expirationDate,
    required this.ingredients,
    required this.ingredientsPresent,
  });
}

class LabelParser {
  /// [textBySlot] maps each captured [PhotoSlot] to the OCR text extracted
  /// from that slot's photo. Missing slots (skipped) yield empty text.
  static LabelFields parse(Map<PhotoSlot, String> textBySlot) {
    final frontText = textBySlot[PhotoSlot.front] ?? '';
    final expirationText = textBySlot[PhotoSlot.expiration] ?? '';
    final ingredientsText = textBySlot[PhotoSlot.ingredients] ?? '';

    final frontLines = frontText
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();

    return LabelFields(
      productName: _extractProductName(frontLines),
      expiration: _extractExpiration(expirationText),
      expirationDate: parseExpiry(expirationText),
      ingredients: _cleanIngredients(ingredientsText),
      ingredientsPresent: ingredientsPresent(ingredientsText),
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

  // ── Expiration ────────────────────────────────────────────────────────────

  static final RegExp _expKeywordRegex = RegExp(
    r'(exp(?:iry|iration)?\.?\s*(?:date)?\s*[:\-]?\s*)'
    r'(\d{4}[\/\-\.]\d{1,2}(?:[\/\-\.]\d{1,2})?|\d{1,2}[\/\-\.]\d{4}|\d{1,2}[\/\-\.]\d{1,2}[\/\-\.]\d{2,4})',
    caseSensitive: false,
  );
  static final RegExp _bareDateRegex = RegExp(
      r'\b(\d{4}[\/\-\.]\d{1,2}(?:[\/\-\.]\d{1,2})?|\d{1,2}[\/\-\.]\d{1,2}[\/\-\.]\d{2,4}|\d{1,2}[\/\-\.]\d{4})\b');

  static String _extractExpiration(String text) {
    final raw = _rawDateString(text);
    return raw ?? 'Not detected';
  }

  /// The date substring found in [text] (near an "EXP" keyword if present,
  /// else the first bare date), or null.
  static String? _rawDateString(String text) {
    if (text.trim().isEmpty) return null;
    final m = _expKeywordRegex.firstMatch(text);
    if (m != null) return m.group(2)!.trim();
    final bare = _bareDateRegex.firstMatch(text);
    if (bare != null) return bare.group(1)!.trim();
    return null;
  }

  /// Parses the expiration slot's OCR [text] into a cutoff [DateTime] (the last
  /// day the product is in date), or null if no date could be read. Callers
  /// treat null as "unreadable → prompt re-scan", and compare a non-null result
  /// against today to decide expired vs. valid.
  static DateTime? parseExpiry(String text) {
    final raw = _rawDateString(text);
    if (raw == null) return null;
    return _parseDateString(raw);
  }

  static DateTime? _parseDateString(String s) {
    final parts = s.split(RegExp(r'[\/\-\.]'));
    final nums = <int>[];
    for (final part in parts) {
      final n = int.tryParse(part);
      if (n == null) return null;
      nums.add(n);
    }

    if (parts.length == 3) {
      int year, month, day;
      if (parts[0].length == 4) {
        // YYYY-MM-DD
        year = nums[0];
        month = nums[1];
        day = nums[2];
      } else {
        // DD/MM/YYYY or MM/DD/YYYY — disambiguate by an out-of-range part,
        // else assume day-first (international / PH common).
        year = parts[2].length == 4 ? nums[2] : 2000 + nums[2];
        if (nums[0] > 12) {
          day = nums[0];
          month = nums[1];
        } else if (nums[1] > 12) {
          month = nums[0];
          day = nums[1];
        } else {
          day = nums[0];
          month = nums[1];
        }
      }
      return _exactDate(year, month, day);
    }

    if (parts.length == 2) {
      // Month precision → cutoff is the last day of that month.
      int year, month;
      if (parts[0].length == 4) {
        year = nums[0];
        month = nums[1]; // YYYY-MM
      } else if (parts[1].length == 4) {
        month = nums[0];
        year = nums[1]; // MM/YYYY
      } else {
        return null; // ambiguous 2-digit/2-digit — don't guess
      }
      if (month < 1 || month > 12) return null;
      return DateTime(year, month + 1, 0); // day 0 of next month = last day
    }

    return null;
  }

  static DateTime? _exactDate(int year, int month, int day) {
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;
    return DateTime(year, month, day);
  }

  // ── Ingredients ───────────────────────────────────────────────────────────

  /// A real ingredient list needs some actual words, not just stray marks —
  /// require a minimum number of alphabetic characters in the OCR output.
  static bool ingredientsPresent(String text) {
    final letters = text.replaceAll(RegExp(r'[^A-Za-z]'), '');
    return letters.length >= 8;
  }

  static String _cleanIngredients(String text) {
    // Strip a leading "Ingredients:" label if present; the photo is dedicated
    // to the ingredient list, so no keyword search is needed to find the start.
    final withoutLabel = text.replaceFirst(
        RegExp(r'^\s*ingredients?\s*[:\-]\s*', caseSensitive: false), '');
    final cleaned = withoutLabel.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.isEmpty) return 'No ingredient list detected';
    return cleaned.length > 500 ? '${cleaned.substring(0, 500)}…' : cleaned;
  }
}
