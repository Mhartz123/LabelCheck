import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

/// A product name from an FDA Philippines advisory (unregistered, recalled,
/// or otherwise flagged) that matched the scanned label's OCR text.
class FdaAdvisoryMatch {
  final String productName;
  final String advisoryNumber;
  final String category;
  final String datePosted;

  const FdaAdvisoryMatch({
    required this.productName,
    required this.advisoryNumber,
    required this.category,
    required this.datePosted,
  });
}

/// Result of a dataset lookup: the confident [match] if the overlap crossed
/// the required threshold, plus [bestRatio] — the strongest word-overlap ratio
/// seen against any advisory name (0..1). [bestRatio] lets the cascade tell a
/// clear miss (ratio near 0) from a *weak/ambiguous* one (ratio close to but
/// under threshold), which is the trigger to escalate to the semantic tier.
class FdaMatchOutcome {
  final FdaAdvisoryMatch? match;
  final double bestRatio;

  const FdaMatchOutcome({required this.match, required this.bestRatio});

  bool get hasConfidentMatch => match != null;
}

class _Entry {
  final String name;
  final String advisory;
  final String category;
  final String date;
  final List<String> words;

  const _Entry({
    required this.name,
    required this.advisory,
    required this.category,
    required this.date,
    required this.words,
  });
}

/// Looks up scanned label text against the FDA Philippines "unregistered
/// health products" advisory list (assets/data/fda_advisories.json, ~20.8k
/// entries converted from the source .xlsx via scripts/convert_fda_dataset.py).
///
/// Matching is a significant-word-overlap heuristic, not exact substring
/// matching: OCR text is noisy (line breaks, misreads) so we require most/all
/// of an advisory product name's meaningful words (length >= 3) to appear
/// anywhere in the scanned text, rather than requiring an exact contiguous
/// phrase. This trades some precision (rare coincidental overlaps on generic
/// words like "whitening capsules") for recall against noisy OCR — acceptable
/// here since a match still only contributes one signal in ComplianceEngine.
class FdaDatasetChecker {
  static const String _assetPath = 'assets/data/fda_advisories.json';
  static final RegExp _wordSplitRegex = RegExp(r'[^A-Z0-9]+');

  static List<_Entry>? _entries;
  static Future<void>? _loading;

  /// Loads and indexes the advisory dataset. Safe to call repeatedly;
  /// subsequent calls reuse the same in-flight/completed load.
  static Future<void> ensureLoaded() {
    return _loading ??= _load();
  }

  static Future<void> _load() async {
    final jsonStr = await rootBundle.loadString(_assetPath);
    final List<dynamic> raw = json.decode(jsonStr) as List<dynamic>;
    _entries = raw.map((row) {
      final list = row as List<dynamic>;
      final name = list[0] as String;
      return _Entry(
        name: name,
        advisory: list[1] as String,
        category: list[2] as String,
        date: list[3] as String,
        words: _significantWords(name),
      );
    }).toList();
  }

  /// Convenience wrapper returning just the confident match (or null). Kept
  /// for callers/tests that don't need the near-miss score.
  static FdaAdvisoryMatch? match(String combinedText) =>
      matchOutcome(combinedText).match;

  /// Only advisory words at least this long are eligible for fuzzy (edit-
  /// distance-1) matching — short words fuzz-match too easily ("OIL"↔"OIS").
  static const int _minFuzzyWordLength = 4;

  /// Fuzzy matching is only attempted on entries whose *exact* overlap already
  /// reached this ratio, both to bound cost (skip the ~10k clear misses) and
  /// because promoting a very-low-overlap entry would be a stretch.
  static const double _fuzzyConsiderationFloor = 0.5;

  /// Returns the first advisory entry whose product name substantially
  /// overlaps with [combinedText] (exact significant-word overlap, then a
  /// bounded edit-distance-1 fuzzy pass to tolerate OCR misreads), along with
  /// the best overlap ratio seen. Call [ensureLoaded] (and await it) first.
  static FdaMatchOutcome matchOutcome(String combinedText) {
    final entries = _entries;
    if (entries == null) {
      return const FdaMatchOutcome(match: null, bestRatio: 0);
    }

    final textWords = _significantWords(combinedText).toSet();
    if (textWords.isEmpty) {
      return const FdaMatchOutcome(match: null, bestRatio: 0);
    }

    var bestRatio = 0.0;
    for (final entry in entries) {
      if (entry.words.isEmpty) continue;

      final exactCount = entry.words.where(textWords.contains).length;
      var ratio = exactCount / entry.words.length;
      final requiredRatio = entry.words.length <= 2 ? 1.0 : 0.8;

      // Fuzzy promotion for near-miss entries only: try to recover words the
      // exact pass missed via a single-edit (OCR misread) match.
      if (ratio < requiredRatio && ratio >= _fuzzyConsiderationFloor) {
        var fuzzyCount = exactCount;
        for (final word in entry.words) {
          if (word.length < _minFuzzyWordLength) continue;
          if (textWords.contains(word)) continue;
          if (_hasSingleEditMatch(word, textWords)) fuzzyCount++;
        }
        ratio = fuzzyCount / entry.words.length;
      }

      if (ratio > bestRatio) bestRatio = ratio;

      if (ratio >= requiredRatio) {
        return FdaMatchOutcome(
          match: FdaAdvisoryMatch(
            productName: entry.name,
            advisoryNumber: entry.advisory,
            category: entry.category,
            datePosted: entry.date,
          ),
          bestRatio: ratio,
        );
      }
    }
    return FdaMatchOutcome(match: null, bestRatio: bestRatio);
  }

  /// True if any word in [textWords] (length >= [_minFuzzyWordLength]) is
  /// within edit distance 1 of [target] — one substitution, insertion, or
  /// deletion, the shape of a typical single-character OCR misread.
  static bool _hasSingleEditMatch(String target, Set<String> textWords) {
    for (final candidate in textWords) {
      if (candidate.length < _minFuzzyWordLength) continue;
      if ((candidate.length - target.length).abs() > 1) continue;
      if (_withinOneEdit(target, candidate)) return true;
    }
    return false;
  }

  static bool _withinOneEdit(String a, String b) {
    if (a == b) return true;
    final la = a.length;
    final lb = b.length;
    if (la == lb) {
      var diffs = 0;
      for (var i = 0; i < la; i++) {
        if (a.codeUnitAt(i) != b.codeUnitAt(i)) {
          if (++diffs > 1) return false;
        }
      }
      return diffs == 1;
    }
    // Lengths differ by 1: allow exactly one insertion/deletion.
    final shorter = la < lb ? a : b;
    final longer = la < lb ? b : a;
    var i = 0;
    var j = 0;
    var edited = false;
    while (i < shorter.length && j < longer.length) {
      if (shorter.codeUnitAt(i) == longer.codeUnitAt(j)) {
        i++;
        j++;
      } else {
        if (edited) return false;
        edited = true;
        j++; // skip the extra char in the longer string
      }
    }
    return true;
  }

  static List<String> _significantWords(String text) {
    return text
        .toUpperCase()
        .split(_wordSplitRegex)
        .where((w) => w.length >= 3)
        .toList();
  }
}
