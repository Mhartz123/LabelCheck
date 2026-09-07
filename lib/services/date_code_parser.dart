import 'dart:ui' show Rect;

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import 'ocr_geometry.dart';

/// Outcome of reading a date code.
///
/// [unreadable] is emphatically not the same thing as "no expiry problem". It
/// mirrors the `available = false` vs `is_damaged = false` distinction already
/// drawn on the damage side: conflating the two inflates the clean counts and
/// lets an unread code pass as fresh. Callers must handle it as its own
/// outcome, never as a pass.
enum DateCodeStatus { parsed, unreadable, ambiguous }

class DateCode {
  final DateTime? manufactured;

  /// Last day the product is in date. Month-precision codes resolve to the
  /// last day of the printed month, matching the existing expiry semantics.
  final DateTime? expiry;

  final String? batch;
  final DateCodeStatus status;

  /// Why the read is unreadable or ambiguous, for the report.
  final String? note;

  /// Name of the pattern the expiry matched, e.g. `DD/MM/YYYY`. Null when no
  /// expiry was read. Carried so the evaluation harness can report accuracy
  /// per printed format rather than as one pooled number — a pipeline that is
  /// perfect on slash-separated dates and blind on compact ones is a different
  /// problem from one that is uniformly mediocre.
  final String? matchedFormat;

  /// The exact substring the expiry was read out of, for the same reason.
  final String? sourceText;

  /// ML Kit's confidence in the line the expiry was read from, 0..1, or null
  /// where the recognizer did not report one (it does not on iOS, and does not
  /// for every model).
  ///
  /// This is the recognizer's confidence in the CHARACTERS, not the parser's
  /// confidence in the date: a crisply recognized string can still be an
  /// ambiguous date, and [status] is what carries that. Kept because section 7
  /// of the integration brief asks the structured result for a confidence, and
  /// because it is a second, independent signal alongside frame agreement.
  final double? confidence;

  const DateCode({
    this.manufactured,
    this.expiry,
    this.batch,
    required this.status,
    this.note,
    this.matchedFormat,
    this.sourceText,
    this.confidence,
  });
}

/// Vertical grouping tolerance for reading order, as a fraction of the median
/// line height. Overprinted values drift off the pre-printed baseline grid, so
/// the buckets have to be looser than a line height.
const double kReadingOrderBucketFactor = 0.7;

/// How far from a label a value may sit, in label heights, for the proximity
/// fallback to accept it.
const double kProximityLineHeights = 1.5;

/// Plausible shelf life. A misread digit usually breaks one of these bounds,
/// which turns a silently wrong answer into a caught error.
const int kMinShelfLifeMonths = 6;
const int kMaxShelfLifeMonths = 72;
const int kMaxExpiryYearsAhead = 10;

/// A date this far in the past is a misread, not a very old product. Without
/// this floor a DD/MM/YY code read as MM/YY resolves into the 2000s and is
/// reported as decades expired with full confidence.
const int kMaxExpiryYearsBehind = 10;

/// Month abbreviations as printed on packaging.
///
/// Alphabetic months are common on Philippine pharmaceutical cartons
/// (`04FEB2028`) and cannot be read after digit normalization, which would
/// turn FEB into FE8, AUG into AU6, OCT into 0C7 and DEC into 0EC. They are
/// matched against the raw text instead.
const Map<String, int> kMonthAbbreviations = <String, int>{
  'JAN': 1,
  'FEB': 2,
  'MAR': 3,
  'APR': 4,
  'MAY': 5,
  'JUN': 6,
  'JUL': 7,
  'AUG': 8,
  'SEP': 9,
  'OCT': 10,
  'NOV': 11,
  'DEC': 12,
};

/// Glyphs ML Kit routinely confuses for digits in a date context.
///
/// Applied to date tokens only. A real batch code looks like `B.177T78`, where
/// the `B` and the `T` are genuine letters — a blanket pass over the whole
/// crop fixes the dates and corrupts the batch number in the same sweep.
const Map<String, String> kDigitLookalikes = <String, String>{
  'O': '0',
  'I': '1',
  'l': '1',
  '|': '1',
  'S': '5',
  'B': '8',
  'Z': '2',
  'G': '6',
  'T': '7',
  'D': '0',
};

/// Reads manufacture/expiry dates and a batch code out of ML Kit's output for
/// the date-code crop.
class DateCodeParser {
  const DateCodeParser._();

  // Anchors are matched against the raw text, never the normalized text: the
  // digit map would turn MFG into MF6 and Batch into 8a7ch. The negative
  // lookahead lets EXP match "EXP03/2028" (no word boundary between P and 0)
  // while still rejecting EXPORT, and the longer spellings come first so they
  // are not shadowed by the short one.
  static final RegExp _mfgAnchor = RegExp(
      r'\b(?:MANUFACTUR[A-Z]*|PRODUCTION|MFG|MFD|PROD)(?![A-Za-z])',
      caseSensitive: false);

  // "BEST BEFORE", "USE BY" and "VALID UNTIL" are as common as EXP on
  // Philippine OTC packaging, and without them a pack carrying one reads as an
  // unlabelled single date and is downgraded to ambiguous. The multi-word forms
  // allow the space to be missing, which is how they come back off a tight
  // crop, and the longer spellings come first so EXPIRY is not shadowed by EXP.
  static final RegExp _expAnchor = RegExp(
      r'\b(?:BEST\s*BEFORE(?:\s*END)?|USE\s*BY'
      r'|VALID\s*(?:UNTIL|THROUGH|THRU|TO)'
      r'|EXPIRATION|EXPIRES|EXPIRY|EXP|BBE|BB)(?![A-Za-z])',
      caseSensitive: false);

  static final RegExp _batchAnchor =
      RegExp(r'\b(?:BATCH|LOT)(?![A-Za-z])', caseSensitive: false);

  /// One separator between date components: punctuation with optional spaces
  /// around it, or plain whitespace on its own. Overprinters use all of them,
  /// and `EXP 10 2028` is no rarer than `EXP 10/2028`.
  // Characters an overprinter can put between date components, as ML Kit
  // returns them. The unicode dashes and the middle dot are not decoration: a
  // dot-matrix hyphen is a short run of dots, and the recognizer resolves it as
  // an en dash, an em dash or a bullet about as often as a plain hyphen.
  static const String _sepChar = r'[\s.,/\-‐‑‒–—―·•]';

  // The repeat count is not cosmetic either. A single carton prints
  // `MAR.--25` — a period AND a doubled dash, three separator characters in a
  // row — and a class capped at two matches none of it. Measured against real
  // captures, not chosen for tidiness.
  static const String _sep = '$_sepChar{1,3}';

  /// As [_sep], but optional — the alphabetic forms are frequently solid, and
  /// the month word anchors the match either way, so a looser bound is safe
  /// here than it would be between two bare numbers.
  static const String _optSep = '$_sepChar{0,4}';

  // Longest first; each match consumes its span so a three-component reading is
  // never re-read as the two-component date sitting inside it.
  //
  // Day and month share ONE pattern rather than having a DD/MM one and an
  // MM/DD one, because which is which is a property of the values, not of
  // whichever regex happened to match first. Two competing patterns let
  // `12/31/2028` fall past the DD/MM pattern (31 is not a month) into a
  // two-component reading of `12/31` as December 2031 — a confident answer
  // three years wrong. See [_dayMonthToken].
  static final RegExp _numericTriple =
      RegExp('(?<!\\d)(\\d{1,2})$_sep(\\d{1,2})$_sep(20\\d{2}|\\d{2})(?!\\d)');

  static final RegExp _monthYear =
      RegExp('(?<!\\d)(0?[1-9]|1[0-2])$_sep(20\\d{2})(?!\\d)');

  static final RegExp _monthShortYear =
      RegExp('(?<!\\d)(0[1-9]|1[0-2])$_sep(\\d{2})(?!\\d)');

  // Separator-less forms, which is how a continuous-inkjet head usually
  // prints. There is no delimiter to key on, so the components are taken
  // positionally and the four-digit year anchors which end is which.
  static final RegExp _compactIso = RegExp(
      r'(?<!\d)(20\d{2})(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])(?!\d)');
  static final RegExp _compactDayMonthYear =
      RegExp(r'(?<!\d)(\d{2})(\d{2})(20\d{2})(?!\d)');
  static final RegExp _compactMonthYear =
      RegExp(r'(?<!\d)(0[1-9]|1[0-2])(20\d{2})(?!\d)');

  static const String _monthNamePattern =
      'JAN|FEB|MAR|APR|MAY|JUN|JUL|AUG|SEP|OCT|NOV|DEC';

  // Alphabetic-month forms, matched against the raw text before normalization.
  // The separator is optional because these are usually printed solid, and a
  // trailing [A-Za-z]* absorbs the long spellings (FEBRUARY, SEPT).
  static final RegExp _dayMonthNameYear = RegExp(
      r'(?<![A-Za-z0-9])(\d{1,2})\s*[-/.]?\s*(?:'
      '$_monthNamePattern'
      r')[A-Za-z]*\s*[-/.]?\s*(20\d{2})(?!\d)',
      caseSensitive: false);
  static final RegExp _monthNameYear = RegExp(
      r'(?<![A-Za-z0-9])(?:'
      '$_monthNamePattern'
      r')[A-Za-z]*\s*[-/.]{0,2}\s*(20\d{2})(?!\d)',
      caseSensitive: false);

  // Two-digit-year alphabetic forms. `MAR--25` is a complete expiry as printed
  // on a Philippine carton, and without these it matches nothing here and is
  // picked up by the batch scanner instead — the date is not merely missed, it
  // is filed as a lot number. The trailing (?!\d) keeps these off a four-digit
  // year, so `JAN 2029` still belongs to the patterns above.
  static final RegExp _dayMonthNameShortYear = RegExp(
      r'(?<![A-Za-z0-9])(\d{1,2})' '$_optSep' r'(?:'
      '$_monthNamePattern'
      r')[A-Za-z]*' '$_optSep' r'(\d{2})(?!\d)',
      caseSensitive: false);
  // Month-first alphabetic order, common on imported product. Low risk to add
  // despite the general danger of more patterns: the month is a WORD, so a lot
  // code cannot fall into it the way a bare six-digit pattern would swallow
  // `120523`.
  static final RegExp _monthNameDayYear = RegExp(
      r'(?<![A-Za-z0-9])(?:'
      '$_monthNamePattern'
      r')[A-Za-z]*' '$_optSep' r'(\d{1,2})' '$_optSep' r'(20\d{2})(?!\d)',
      caseSensitive: false);

  static final RegExp _monthNameShortYear = RegExp(
      r'(?<![A-Za-z0-9])(?:'
      '$_monthNamePattern'
      r')[A-Za-z]*' '$_optSep' r'(\d{2})(?!\d)',
      caseSensitive: false);

  /// ISO order, which some overprinters use: 2028-02-04.
  static final RegExp _isoDate = RegExp(
      r'(?<!\d)(20\d{2})\s*[-/.]\s*(0[1-9]|1[0-2])\s*[-/.]\s*'
      r'(0[1-9]|[12]\d|3[01])(?!\d)');

  /// Pulls the month abbreviation back out of a matched alphabetic date.
  static final RegExp _monthNameIn =
      RegExp('($_monthNamePattern)', caseSensitive: false);

  /// A batch code: at least four characters of alphanumerics and separators,
  /// carrying at least one digit. Read off the raw text with the label and
  /// date spans blanked out.
  static final RegExp _batchCandidate = RegExp(r'[A-Za-z0-9][A-Za-z0-9./\-]{3,}');

  /// Parses the date code out of [recognized].
  ///
  /// [today] is injectable so the "not more than [kMaxExpiryYearsAhead] years
  /// ahead" check is deterministic under test.
  static DateCode parse(
    RecognizedText recognized, {
    double maxSkewDegrees = kDateCodeMaxSkewDegrees,
    DateTime? today,
  }) {
    final lines =
        OcrGeometry.horizontalLines(recognized, maxSkewDegrees: maxSkewDegrees);
    return parseLines(lines, today: today);
  }

  /// As [parse], for callers that have already filtered the lines.
  static DateCode parseLines(List<TextLine> lines, {DateTime? today}) {
    final ordered = _readingOrder(lines);

    final anchors = <_Anchor>[];
    final tokens = <_DateToken>[];
    final batches = <_BatchCandidate>[];
    for (var i = 0; i < ordered.length; i++) {
      _scanLine(ordered[i], i, anchors, tokens, batches);
    }
    anchors.sort(_byReadingPosition);
    tokens.sort(_byReadingPosition);

    final batch = _pickBatch(anchors, batches);
    final dateAnchors = anchors
        .where((a) => a.kind != _AnchorKind.batch)
        .toList(growable: false);

    _DateToken? manufacturedToken;
    _DateToken? expiryToken;
    var status = DateCodeStatus.parsed;
    String? note;

    if (dateAnchors.isNotEmpty && dateAnchors.length == tokens.length) {
      // Zip in reading order. This is the case that matters: when an
      // overprinted value sits on a different baseline grid from its
      // pre-printed label, nearest-baseline association binds it to the
      // neighbouring label and reports an expired product as fresh. Ordinal
      // position survives the drift; vertical distance does not.
      for (var i = 0; i < dateAnchors.length; i++) {
        if (dateAnchors[i].kind == _AnchorKind.mfg) {
          manufacturedToken ??= tokens[i];
        } else {
          expiryToken ??= tokens[i];
        }
      }
    } else if (dateAnchors.isNotEmpty) {
      status = DateCodeStatus.ambiguous;
      note = 'Date labels and values did not line up; matched by proximity.';
      for (final anchor in dateAnchors) {
        final token = _nearestToken(anchor, tokens);
        if (token == null) continue;
        if (anchor.kind == _AnchorKind.mfg) {
          manufacturedToken ??= token;
        } else {
          expiryToken ??= token;
        }
      }
    } else if (tokens.length == 2) {
      final sorted = List<_DateToken>.of(tokens)
        ..sort((a, b) => a.asExpiry.compareTo(b.asExpiry));
      manufacturedToken = sorted.first;
      expiryToken = sorted.last;
    } else if (tokens.length == 1) {
      // The most common single marking on a pack is the expiry, but it is a
      // guess and has to be reported as one.
      expiryToken = tokens.first;
      status = DateCodeStatus.ambiguous;
      note = 'Single unlabelled date read; assumed to be the expiry.';
    } else if (tokens.length > 2) {
      final sorted = List<_DateToken>.of(tokens)
        ..sort((a, b) => a.asExpiry.compareTo(b.asExpiry));
      manufacturedToken = sorted.first;
      expiryToken = sorted.last;
      status = DateCodeStatus.ambiguous;
      note = '${tokens.length} unlabelled dates read; '
          'assumed the earliest and latest.';
    }

    // A day/month pair that the printed code itself does not disambiguate is
    // a real uncertainty about the date, not a detail of how it was matched,
    // so it has to reach the compliance engine as one.
    if (expiryToken != null && expiryToken.orderAmbiguous) {
      status = DateCodeStatus.ambiguous;
      const ordering = 'Day and month are both 12 or under, so the printed '
          'order could not be determined; read as day first.';
      note = note == null ? ordering : '$note $ordering';
    }

    return _validate(
      manufactured: manufacturedToken?.asManufactured,
      expiry: expiryToken?.asExpiry,
      batch: batch,
      status: status,
      note: note,
      matchedFormat: expiryToken?.format,
      sourceText: expiryToken?.source,
      confidence: expiryToken == null
          ? null
          : ordered[expiryToken.lineIndex].confidence,
      today: today ?? DateTime.now(),
    );
  }

  // ── Structural validation ────────────────────────────────────────────────

  /// Cross-checks the pair and fails loudly. A misread digit usually breaks
  /// one of these, so the check converts a silently wrong date into a caught
  /// error. On failure both dates are dropped rather than one, so an
  /// [DateCodeStatus.unreadable] result can never be mistaken for a usable
  /// reading.
  static DateCode _validate({
    required DateTime? manufactured,
    required DateTime? expiry,
    required String? batch,
    required DateCodeStatus status,
    required String? note,
    required String? matchedFormat,
    required String? sourceText,
    required double? confidence,
    required DateTime today,
  }) {
    DateCode unreadable(String why) =>
        DateCode(batch: batch, status: DateCodeStatus.unreadable, note: why);

    if (manufactured == null && expiry == null) {
      return unreadable(note ?? 'No readable date code found.');
    }

    if (expiry == null) {
      return unreadable(
          'A manufacture date was read but no expiry date was found.');
    }

    final horizon =
        DateTime(today.year + kMaxExpiryYearsAhead, today.month, today.day);
    if (expiry.isAfter(horizon)) {
      return unreadable('Expiry reads more than $kMaxExpiryYearsAhead years '
          'ahead, so at least one digit was misread.');
    }

    // The floor matters as much as the horizon. A DD/MM/YY code mis-read as
    // MM/YY lands in the early 2000s, which is not a very old product but a
    // misread — and without this it would be reported as decades expired with
    // no hint that anything went wrong.
    final floor =
        DateTime(today.year - kMaxExpiryYearsBehind, today.month, today.day);
    if (expiry.isBefore(floor)) {
      return unreadable('Expiry reads more than $kMaxExpiryYearsBehind years '
          'in the past, so at least one digit was misread.');
    }

    if (manufactured != null) {
      if (!expiry.isAfter(manufactured)) {
        return unreadable(
            'Expiry date is not after the manufacture date, so the two were '
            'misread or swapped.');
      }
      final months = (expiry.year * 12 + expiry.month) -
          (manufactured.year * 12 + manufactured.month);
      if (months < kMinShelfLifeMonths || months > kMaxShelfLifeMonths) {
        return unreadable('Gap of $months months between manufacture and '
            'expiry is outside the plausible $kMinShelfLifeMonths-'
            '$kMaxShelfLifeMonths month shelf life.');
      }
    }

    return DateCode(
      manufactured: manufactured,
      expiry: expiry,
      batch: batch,
      status: status,
      note: note,
      matchedFormat: matchedFormat,
      sourceText: sourceText,
      confidence: confidence,
    );
  }

  // ── Line scanning ────────────────────────────────────────────────────────

  static void _scanLine(
    TextLine line,
    int index,
    List<_Anchor> anchors,
    List<_DateToken> tokens,
    List<_BatchCandidate> batches,
  ) {
    final raw = line.text;
    if (raw.isEmpty) return;
    final box = line.boundingBox;

    // Spans already claimed by a label or a date. Blanking them keeps each
    // pass from re-reading what an earlier one already accounted for.
    final claimed = List<bool>.filled(raw.length, false);
    void claim(int start, int end) {
      for (var i = start; i < end && i < claimed.length; i++) {
        claimed[i] = true;
      }
    }

    const anchorPatterns = <_AnchorKind>[
      _AnchorKind.mfg,
      _AnchorKind.exp,
      _AnchorKind.batch,
    ];
    for (final kind in anchorPatterns) {
      for (final match in _anchorPattern(kind).allMatches(raw)) {
        anchors.add(_Anchor(kind, index, match.start, box));
        claim(match.start, match.end);
      }
    }

    // Alphabetic-month and ISO dates come first, and off text whose digits are
    // normalized everywhere EXCEPT inside the month word. Blanket normalization
    // would turn 04FEB2028 into 04FE82028 and destroy the month before it could
    // be matched; leaving the text raw instead loses the other half, because a
    // dot-matrix year comes back as 30SEP2S or 30SEP2B as often as 30SEP25 and
    // the two-digit year then matches nothing at all.
    final monthSafe = _normalizeAroundMonths(_mask(raw, claimed));
    for (final spec in _rawPatterns) {
      _collect(spec, monthSafe, index, box, claimed, tokens, claim);
    }

    // Digit normalization then applies to whatever is left, which by now has
    // both the labels and any alphabetic date removed — so MFG cannot
    // contribute a stray 6 to the digits beside it.
    final normalized = _normalizeDigits(_mask(raw, claimed));

    for (final spec in _digitPatterns) {
      _collect(spec, normalized, index, box, claimed, tokens, claim);
    }

    // Batch candidates come off the raw text, never the normalized text.
    for (final match in _batchCandidate.allMatches(_mask(raw, claimed))) {
      final text = match.group(0)!;
      if (!text.contains(RegExp(r'\d'))) continue;
      batches.add(_BatchCandidate(text, index, match.start, box));
    }
  }

  static RegExp _anchorPattern(_AnchorKind kind) => switch (kind) {
        _AnchorKind.mfg => _mfgAnchor,
        _AnchorKind.exp => _expAnchor,
        _AnchorKind.batch => _batchAnchor,
      };

  static String _mask(String source, List<bool> claimed) {
    final buffer = StringBuffer();
    for (var i = 0; i < source.length; i++) {
      buffer.write(claimed[i] ? ' ' : source[i]);
    }
    return buffer.toString();
  }

  static bool _anyClaimed(List<bool> claimed, int start, int end) {
    for (var i = start; i < end && i < claimed.length; i++) {
      if (claimed[i]) return true;
    }
    return false;
  }

  /// Every month word in [source], including any long-spelling tail, so those
  /// spans can be held back from digit normalization.
  static final RegExp _monthWord = RegExp(
      '(?:$_monthNamePattern)[A-Za-z]*',
      caseSensitive: false);

  /// Digit-normalizes [source] but leaves month words untouched.
  ///
  /// Substitution stays one character for one, so offsets into the result line
  /// up with the raw text and [claim] spans stay valid.
  static String _normalizeAroundMonths(String source) {
    final protected = List<bool>.filled(source.length, false);
    for (final match in _monthWord.allMatches(source)) {
      for (var i = match.start; i < match.end; i++) {
        protected[i] = true;
      }
    }
    final buffer = StringBuffer();
    for (var i = 0; i < source.length; i++) {
      final ch = source[i];
      buffer.write(protected[i] ? ch : (kDigitLookalikes[ch] ?? ch));
    }
    return buffer.toString();
  }

  /// Substitutes digit lookalikes one for one, so offsets into the result
  /// still line up with the raw text.
  static String _normalizeDigits(String source) {
    final buffer = StringBuffer();
    for (var i = 0; i < source.length; i++) {
      final ch = source[i];
      buffer.write(kDigitLookalikes[ch] ?? ch);
    }
    return buffer.toString();
  }

  /// Runs one pattern over [text] and files any tokens it yields.
  static void _collect(
    _DatePattern spec,
    String text,
    int lineIndex,
    Rect box,
    List<bool> claimed,
    List<_DateToken> tokens,
    void Function(int, int) claim,
  ) {
    for (final match in spec.pattern.allMatches(text)) {
      if (_anyClaimed(claimed, match.start, match.end)) continue;
      final token = spec.build(match, spec.name, lineIndex, box);
      if (token == null) continue;
      tokens.add(token);
      claim(match.start, match.end);
    }
  }

  /// Patterns read off the raw text, before digit normalization.
  static final List<_DatePattern> _rawPatterns = <_DatePattern>[
    _DatePattern('DD MMM YYYY', _dayMonthNameYear, (m, name, i, box) {
      final month = _monthOf(m.group(0)!);
      if (month == null) return null;
      return _dateToken(
          int.parse(m.group(2)!), month, int.parse(m.group(1)!), name, m, i, box);
    }),
    _DatePattern('DD MMM YY', _dayMonthNameShortYear, (m, name, i, box) {
      final month = _monthOf(m.group(0)!);
      if (month == null) return null;
      return _dateToken(2000 + int.parse(m.group(2)!), month,
          int.parse(m.group(1)!), name, m, i, box);
    }),
    _DatePattern('MMM DD YYYY', _monthNameDayYear, (m, name, i, box) {
      final month = _monthOf(m.group(0)!);
      if (month == null) return null;
      return _dateToken(int.parse(m.group(2)!), month, int.parse(m.group(1)!),
          name, m, i, box);
    }),
    _DatePattern('MMM YYYY', _monthNameYear, (m, name, i, box) {
      final month = _monthOf(m.group(0)!);
      if (month == null) return null;
      return _dateToken(int.parse(m.group(1)!), month, null, name, m, i, box);
    }),
    _DatePattern('MMM YY', _monthNameShortYear, (m, name, i, box) {
      final month = _monthOf(m.group(0)!);
      if (month == null) return null;
      return _dateToken(2000 + int.parse(m.group(1)!), month, null, name, m, i,
          box);
    }),
    _DatePattern('YYYY/MM/DD', _isoDate, (m, name, i, box) => _dateToken(
        int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!),
        name, m, i, box)),
  ];

  /// Patterns read off the digit-normalized text. Order matters: each match
  /// claims its span, so the longer forms have to run first or a compact
  /// eight-digit code is shredded into a shorter reading of its own prefix.
  static final List<_DatePattern> _digitPatterns = <_DatePattern>[
    _DatePattern('YYYYMMDD', _compactIso, (m, name, i, box) => _dateToken(
        int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!),
        name, m, i, box)),
    _DatePattern('DDMMYYYY', _compactDayMonthYear, (m, name, i, box) =>
        _dayMonthToken(int.parse(m.group(1)!), int.parse(m.group(2)!),
            int.parse(m.group(3)!), name, m, i, box)),
    _DatePattern('DD/MM/YYYY', _numericTriple, (m, name, i, box) {
      final raw = m.group(3)!;
      // A two-digit year is read into the 2000s, matching every other
      // short-year form here.
      final year = raw.length == 4 ? int.parse(raw) : 2000 + int.parse(raw);
      return _dayMonthToken(int.parse(m.group(1)!), int.parse(m.group(2)!),
          year, raw.length == 4 ? name : 'DD/MM/YY', m, i, box);
    }),
    _DatePattern('MM/YYYY', _monthYear, (m, name, i, box) => _dateToken(
        int.parse(m.group(2)!), int.parse(m.group(1)!), null, name, m, i, box)),
    _DatePattern('MMYYYY', _compactMonthYear, (m, name, i, box) => _dateToken(
        int.parse(m.group(2)!), int.parse(m.group(1)!), null, name, m, i, box)),
    _DatePattern('MM/YY', _monthShortYear, (m, name, i, box) => _dateToken(
        2000 + int.parse(m.group(2)!), int.parse(m.group(1)!), null,
        name, m, i, box)),
  ];

  /// Builds a token from components whose roles are already known.
  static _DateToken? _dateToken(
    int year,
    int month,
    int? day,
    String format,
    RegExpMatch match,
    int lineIndex,
    Rect box,
  ) {
    if (month < 1 || month > 12) return null;
    if (day != null && (day < 1 || day > _daysInMonth(year, month))) return null;
    return _DateToken(
      year,
      month,
      day,
      lineIndex,
      match.start,
      box,
      format: format,
      source: match.group(0)!,
    );
  }

  /// Builds a token from two components whose roles are NOT known, deciding
  /// day-versus-month from the values themselves.
  ///
  /// Only one of the pair can exceed 12, so a value that does settles the
  /// order outright. When neither does the printed code genuinely does not say
  /// which convention was used — `04/02/2028` is the fourth of February to
  /// most of the world and the second of April to a US supplier — so the
  /// reading is marked ambiguous and carries the day-first default rather than
  /// being silently presented as certain.
  static _DateToken? _dayMonthToken(
    int first,
    int second,
    int year,
    String format,
    RegExpMatch match,
    int lineIndex,
    Rect box,
  ) {
    int day;
    int month;
    var ordered = true;
    if (first > 12 && second <= 12) {
      day = first;
      month = second;
    } else if (second > 12 && first <= 12) {
      month = first;
      day = second;
    } else if (first <= 12 && second <= 12) {
      day = first;
      month = second;
      ordered = false;
    } else {
      return null;
    }

    if (month < 1 || day < 1 || day > _daysInMonth(year, month)) return null;
    return _DateToken(
      year,
      month,
      day,
      lineIndex,
      match.start,
      box,
      format: ordered ? format : '$format (order ambiguous)',
      source: match.group(0)!,
      orderAmbiguous: !ordered,
    );
  }


  /// The month number for the abbreviation inside [text], or null.
  static int? _monthOf(String text) {
    final match = _monthNameIn.firstMatch(text);
    if (match == null) return null;
    return kMonthAbbreviations[match.group(1)!.toUpperCase()];
  }

  static int _daysInMonth(int year, int month) =>
      DateTime(year, month + 1, 0).day;

  // ── Reading order ────────────────────────────────────────────────────────

  /// Sorts [lines] into reading order: grouped into rows by vertical position,
  /// then left to right within each row.
  ///
  /// Rows are grown greedily against a tolerance derived from the median line
  /// height rather than cut on a fixed grid, because an overprinted value can
  /// sit most of a line height away from the label it belongs to and a fixed
  /// grid would drop it into the wrong row. The zip in [parseLines] only needs
  /// relative vertical order to survive, which this preserves either way.
  static List<TextLine> _readingOrder(List<TextLine> lines) {
    if (lines.length < 2) return List<TextLine>.of(lines);

    final heights = <double>[for (final line in lines) line.boundingBox.height]
      ..sort();
    final median = heights[heights.length ~/ 2];
    final tolerance = (median <= 0 ? 1.0 : median) * kReadingOrderBucketFactor;

    final sorted = List<TextLine>.of(lines)
      ..sort((a, b) =>
          a.boundingBox.center.dy.compareTo(b.boundingBox.center.dy));

    final ordered = <TextLine>[];
    var row = <TextLine>[];
    var rowAnchor = sorted.first.boundingBox.center.dy;

    void flush() {
      row.sort((a, b) => a.boundingBox.left.compareTo(b.boundingBox.left));
      ordered.addAll(row);
      row = <TextLine>[];
    }

    for (final line in sorted) {
      final y = line.boundingBox.center.dy;
      if (row.isNotEmpty && (y - rowAnchor).abs() > tolerance) {
        flush();
        rowAnchor = y;
      }
      row.add(line);
    }
    flush();
    return ordered;
  }

  static int _byReadingPosition(_Positioned a, _Positioned b) {
    final byLine = a.lineIndex.compareTo(b.lineIndex);
    return byLine != 0 ? byLine : a.offset.compareTo(b.offset);
  }

  // ── Fallback association ─────────────────────────────────────────────────

  /// Nearest token to the right of [anchor] and within
  /// [kProximityLineHeights] label heights of it.
  static _DateToken? _nearestToken(_Anchor anchor, List<_DateToken> tokens) {
    final height = anchor.box.height <= 0 ? 1.0 : anchor.box.height;
    final limit = height * kProximityLineHeights;
    _DateToken? best;
    var bestDistance = double.infinity;

    for (final token in tokens) {
      final sameLine = token.lineIndex == anchor.lineIndex;
      final rightOfAnchor = sameLine
          ? token.offset > anchor.offset
          : token.box.left >= anchor.box.left;
      if (!rightOfAnchor) continue;

      final distance =
          (token.box.center.dy - anchor.box.center.dy).abs();
      if (distance > limit) continue;
      if (distance < bestDistance) {
        bestDistance = distance;
        best = token;
      }
    }
    return best;
  }

  static String? _pickBatch(
    List<_Anchor> anchors,
    List<_BatchCandidate> candidates,
  ) {
    if (candidates.isEmpty) return null;
    if (candidates.length == 1) return candidates.first.text;

    final batchAnchors =
        anchors.where((a) => a.kind == _AnchorKind.batch).toList();
    if (batchAnchors.isEmpty) return null;

    final anchor = batchAnchors.first;
    final height = anchor.box.height <= 0 ? 1.0 : anchor.box.height;
    final limit = height * kProximityLineHeights;
    _BatchCandidate? best;
    var bestDistance = double.infinity;
    for (final candidate in candidates) {
      final distance =
          (candidate.box.center.dy - anchor.box.center.dy).abs();
      if (distance > limit) continue;
      if (distance < bestDistance) {
        bestDistance = distance;
        best = candidate;
      }
    }
    // On a label-column layout the value block can sit well over a line height
    // away from the label it belongs to, which is the same drift the date zip
    // exists to survive. Falling back to reading order keeps the batch rather
    // than dropping it, since a batch code has no structure to validate and
    // reporting the wrong one is no worse than reporting none.
    return (best ?? candidates.first).text;
  }
}

enum _AnchorKind { mfg, exp, batch }

/// Anything carrying a position in reading order.
abstract class _Positioned {
  int get lineIndex;
  int get offset;
}

class _Anchor implements _Positioned {
  final _AnchorKind kind;
  @override
  final int lineIndex;
  @override
  final int offset;
  final Rect box;

  const _Anchor(this.kind, this.lineIndex, this.offset, this.box);
}

/// One date format the scanner knows, with the builder that turns a match of
/// it into a token. Bundling the two keeps the format's name attached to the
/// pattern that produced it, which is what the evaluation harness reports on.
class _DatePattern {
  final String name;
  final RegExp pattern;
  final _DateToken? Function(RegExpMatch, String, int, Rect) build;

  const _DatePattern(this.name, this.pattern, this.build);
}

class _DateToken implements _Positioned {
  final int year;
  final int month;

  /// Null for a month-precision code such as `03/2028`.
  final int? day;

  @override
  final int lineIndex;
  @override
  final int offset;
  final Rect box;

  /// Name of the pattern that produced this token.
  final String format;

  /// The substring it was read out of.
  final String source;

  /// True when day and month could not be told apart from their values.
  final bool orderAmbiguous;

  const _DateToken(
    this.year,
    this.month,
    this.day,
    this.lineIndex,
    this.offset,
    this.box, {
    this.format = '',
    this.source = '',
    this.orderAmbiguous = false,
  });

  /// A month-precision manufacture date starts on the first of the month.
  DateTime get asManufactured => DateTime(year, month, day ?? 1);

  /// A month-precision expiry runs to the last day of the month, matching the
  /// cutoff semantics the compliance check already uses.
  DateTime get asExpiry =>
      day != null ? DateTime(year, month, day!) : DateTime(year, month + 1, 0);
}

class _BatchCandidate implements _Positioned {
  final String text;
  @override
  final int lineIndex;
  @override
  final int offset;
  final Rect box;

  const _BatchCandidate(this.text, this.lineIndex, this.offset, this.box);
}
