import 'dart:io';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import '../models/scan_record.dart';
import 'scan_store.dart';

/// Builds the Product Compliance Summary Report PDF from all saved photos.
class ReportBuilder {
  // ── Colour palette matching the app's soft-green theme ──────────────────
  static const _green = PdfColor.fromInt(0xFF2E7D32);
  static const _greenLight = PdfColor.fromInt(0xFF4CAF50);
  static const _greenBg = PdfColor.fromInt(0xFFE8F5E9);
  static const _amber = PdfColor.fromInt(0xFFE65100);
  static const _amberBg = PdfColor.fromInt(0xFFFFF8E1);
  static const _red = PdfColor.fromInt(0xFFB71C1C);
  static const _redBg = PdfColor.fromInt(0xFFFFEBEE);
  static const _border = PdfColor.fromInt(0xFFC8E0CE);
  static const _muted = PdfColor.fromInt(0xFF6A8F6E);
  static const _text = PdfColor.fromInt(0xFF1A2E1C);
  static const _bg = PdfColor.fromInt(0xFFF0F7F2);
  static const _warningBg = PdfColor.fromInt(0xFFFFF8E1);
  static const _warningText = PdfColor.fromInt(0xFF5C4A1E);

  // Damage-box overlay: amber reads against cardboard without implying a
  // compliance verdict the way the report's red/green would.
  static const _boxStroke = PdfColor.fromInt(0xFFFFB300);
  static const _boxChip = PdfColor.fromInt(0xFFE65100);

  /// Width each evidence photo is drawn at in the PDF, in points, and the
  /// pixel width the JPEG is downscaled to before embedding. Full-resolution
  /// captures would balloon the file for no visible gain at this print size.
  static const double _evidenceWidth = 168;
  static const int _evidencePixelWidth = 700;

  /// Loads all record folders and their data.json files and builds the PDF.
  /// Returns the in-memory PDF bytes ready for [Printing.layoutPdf].
  static Future<pw.Document> build() async {
    final dir = await ScanStore.rootDir();
    return buildFromDirs(_loadAllRecordDirs(dir));
  }

  /// Builds the report over an explicit set of record folders.
  ///
  /// Split out from [build] so tests can exercise the whole pipeline —
  /// including photo decoding and the damage-evidence layout — against a
  /// temp folder, without needing path_provider's platform channel.
  @visibleForTesting
  static Future<pw.Document> buildFromDirs(List<Directory> dirs) async {
    final records = _parseRecords(dirs);
    final evidence = await _loadDamageEvidence(records);
    return _buildDocument(records, evidence);
  }

  // ── Record loading ───────────────────────────────────────────────────────

  static List<Directory> _loadAllRecordDirs(Directory dir) {
    if (!dir.existsSync()) return [];
    return dir
        .listSync()
        .whereType<Directory>()
        .toList()
      ..sort((a, b) => b
          .statSync()
          .modified
          .compareTo(a.statSync().modified));
  }

  static List<_Record> _parseRecords(List<Directory> dirs) {
    return dirs.map((d) {
      final record = ScanStore.load(d);
      return _Record(
        name: p.basename(d.path),
        date: record?.scannedAt ?? d.statSync().modified,
        status: record?.statusLabel ?? '—',
        keyword: record?.matchedKeyword ?? '—',
        dir: d,
        scan: record,
      );
    }).toList();
  }

  // ── Damage evidence ───────────────────────────────────────────────────────

  /// Loads and downscales the packaging photos that carry damage boxes.
  ///
  /// Only photos with at least one detection are read — a clean scan
  /// contributes nothing, so a report over mostly-clean records stays small.
  /// Decoding is the expensive part, so this runs once up front rather than
  /// inside the page builder, which the pdf package may call more than once
  /// while it paginates.
  static Future<List<_Evidence>> _loadDamageEvidence(
      List<_Record> records) async {
    final out = <_Evidence>[];

    for (final r in records) {
      final damage = r.scan?.damageCheck;
      if (damage == null || !damage.isDamaged || damage.boxes.isEmpty) continue;

      final photos = ScanStore.boxPhotosInOrder(r.dir);
      final byPhoto = <int, List<DamageDetection>>{};
      for (final d in damage.boxes) {
        if (d.sourceIndex < 0 || d.sourceIndex >= photos.length) continue;
        byPhoto.putIfAbsent(d.sourceIndex, () => []).add(d);
      }

      for (final index in byPhoto.keys.toList()..sort()) {
        final image = await _downscale(photos[index]);
        if (image == null) continue;
        out.add(_Evidence(
          recordName: r.name,
          date: r.date,
          image: image.image,
          aspect: image.aspect,
          boxes: byPhoto[index]!,
          summary: damage.detectionSummary,
          packaging: r.scan?.packagingType?.label ?? 'Packaging',
        ));
      }
    }
    return out;
  }

  /// Re-encodes one photo down to [_evidencePixelWidth]. Returns null rather
  /// than throwing if the file is missing or won't decode — a report should
  /// still generate when one photo has gone bad.
  static Future<({pw.MemoryImage image, double aspect})?> _downscale(
      File file) async {
    try {
      final decoded = img.decodeImage(await file.readAsBytes());
      if (decoded == null) return null;
      // Bake orientation before measuring: the damage boxes were computed in
      // baked space, so a rotated capture would otherwise get a transposed
      // aspect ratio and boxes in the wrong places.
      final oriented = img.bakeOrientation(decoded);
      final resized = oriented.width > _evidencePixelWidth
          ? img.copyResize(oriented, width: _evidencePixelWidth)
          : oriented;
      if (resized.width == 0 || resized.height == 0) return null;
      return (
      image: pw.MemoryImage(img.encodeJpg(resized, quality: 80)),
      aspect: resized.width / resized.height,
      );
    } catch (_) {
      return null;
    }
  }

  static pw.Widget _evidenceSection(List<_Evidence> evidence) {
    if (evidence.isEmpty) {
      return _emptyNote('No packaging damage was detected in these scans.');
    }
    return pw.Wrap(
      spacing: 12,
      runSpacing: 12,
      children: evidence.map(_evidenceCard).toList(),
    );
  }

  static pw.Widget _evidenceCard(_Evidence e) {
    // The boxes are fractions of the photo, so once the drawn width is fixed
    // the height follows from the image's own aspect ratio and every box
    // scales by the same two numbers.
    final w = _evidenceWidth - 12; // inside the card's padding
    final h = w / e.aspect;

    return pw.Container(
      width: _evidenceWidth,
      decoration: pw.BoxDecoration(
        color: _bg,
        border: pw.Border.all(color: _border),
        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
      ),
      padding: const pw.EdgeInsets.all(6),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Stack(
            children: [
              pw.Image(e.image, width: w, height: h),
              for (final d in e.boxes)
                pw.Positioned(
                  left: d.left * w,
                  top: d.top * h,
                  child: pw.Container(
                    width: d.width * w,
                    height: d.height * h,
                    decoration: pw.BoxDecoration(
                      border: pw.Border.all(color: _boxStroke, width: 1.2),
                    ),
                  ),
                ),
            ],
          ),
          pw.SizedBox(height: 5),
          pw.Text(
            _pdfSafe(e.recordName),
            maxLines: 1,
            overflow: pw.TextOverflow.clip,
            style: pw.TextStyle(
                fontSize: 8, fontWeight: pw.FontWeight.bold, color: _text),
          ),
          pw.SizedBox(height: 2),
          pw.Container(
            padding:
            const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 1.5),
            decoration: pw.BoxDecoration(
              color: _boxChip,
              borderRadius: const pw.BorderRadius.all(pw.Radius.circular(2)),
            ),
            child: pw.Text(
              _pdfSafe(e.summary),
              style: const pw.TextStyle(
                  fontSize: 6.5, color: PdfColor.fromInt(0xFFFFFFFF)),
            ),
          ),
          pw.SizedBox(height: 3),
          pw.Text(_pdfSafe('${e.packaging} - ${_fmtDate(e.date)}'),
              style: pw.TextStyle(fontSize: 6.5, color: _muted)),
        ],
      ),
    );
  }

  // ── PDF construction ──────────────────────────────────────────────────────

  static pw.Document _buildDocument(
      List<_Record> records, List<_Evidence> evidence) {
    final doc = pw.Document();

    // Aggregate stats
    final total = records.length;
    final compliant =
        records.where((r) => r.status == 'COMPLIANT').length;
    final nonCompliant =
        records.where((r) => r.status == 'NON-COMPLIANT').length;
    final banned =
        records.where((r) => r.status == 'WARNING / BANNED').length;

    final flagged = records
        .where((r) =>
    r.status == 'NON-COMPLIANT' || r.status == 'WARNING / BANNED')
        .toList();

    // Common flag trigger frequency
    final triggerFreq = <String, int>{};
    for (final r in flagged) {
      if (r.keyword != '—' && r.keyword.isNotEmpty) {
        triggerFreq[r.keyword] = (triggerFreq[r.keyword] ?? 0) + 1;
      }
    }
    final sortedTriggers = triggerFreq.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    // Date range
    final dates = records.map((r) => r.date).toList()..sort();
    final earliest = dates.isNotEmpty ? _fmtDate(dates.first) : '-';
    final latest = dates.isNotEmpty ? _fmtDate(dates.last) : '-';
    final generated = _fmtDatetime(DateTime.now());

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(36),
        build: (ctx) => [
          _header(generated, earliest, latest),
          pw.SizedBox(height: 16),
          _disclaimer(),
          pw.SizedBox(height: 20),
          _sectionTitle('Overview'),
          pw.SizedBox(height: 8),
          _overviewRow(total, compliant, nonCompliant, banned),
          pw.SizedBox(height: 20),
          _sectionTitle('Common Flag Triggers'),
          pw.SizedBox(height: 8),
          if (sortedTriggers.isEmpty)
            _emptyNote('No flagged records found.')
          else
            _triggerTable(sortedTriggers, flagged.length),
          pw.SizedBox(height: 20),
          _sectionTitle('Flagged Records'),
          pw.SizedBox(height: 8),
          if (flagged.isEmpty)
            _emptyNote('No flagged records.')
          else
            _flaggedTable(flagged),
          pw.SizedBox(height: 20),
          _sectionTitle('Packaging Damage Evidence'),
          pw.SizedBox(height: 4),
          pw.Text(
            'Photos the on-device detector flagged, with the regions it '
                'reacted to outlined. Percentages are model confidence, not a '
                'severity grade.',
            style: pw.TextStyle(fontSize: 8.5, color: _muted),
          ),
          pw.SizedBox(height: 8),
          _evidenceSection(evidence),
          pw.SizedBox(height: 20),
          _sectionTitle('Compliant Products'),
          pw.SizedBox(height: 8),
          _compliantSection(
              records.where((r) => r.status == 'COMPLIANT').toList()),
          pw.SizedBox(height: 24),
          _hotlineFooter(),
        ],
        footer: (ctx) => pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text('Generated by CheckMuna',
                style: pw.TextStyle(fontSize: 9, color: _muted)),
            pw.Text('Page ${ctx.pageNumber} of ${ctx.pagesCount}',
                style: pw.TextStyle(fontSize: 9, color: _muted)),
          ],
        ),
      ),
    );

    return doc;
  }

  // ── Section builders ──────────────────────────────────────────────────────

  static pw.Widget _header(
      String generated, String earliest, String latest) {
    return pw.Container(
      width: double.infinity,
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(
            'CheckMuna',
            style: pw.TextStyle(
              fontSize: 28,
              fontWeight: pw.FontWeight.bold,
              color: _green,
            ),
          ),
          pw.SizedBox(height: 4),
          pw.Text(
            'Product Compliance Summary Report',
            style: pw.TextStyle(
                fontSize: 16,
                fontWeight: pw.FontWeight.bold,
                color: _text),
          ),
          pw.SizedBox(height: 6),
          pw.Divider(color: _greenLight, thickness: 1.5),
          pw.SizedBox(height: 4),
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text('Generated: $generated',
                  style: pw.TextStyle(fontSize: 9, color: _muted)),
              pw.Text(_pdfSafe('Period: $earliest - $latest'),
                  style: pw.TextStyle(fontSize: 9, color: _muted)),
            ],
          ),
        ],
      ),
    );
  }

  static pw.Widget _disclaimer() {
    return pw.Container(
      padding: const pw.EdgeInsets.all(10),
      decoration: pw.BoxDecoration(
        color: _warningBg,
        border: pw.Border.all(color: PdfColor.fromInt(0xFFFFE082)),
        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
      ),
      child: pw.Text(
        'This report is generated by CheckMuna based on automated label scanning and '
            'keyword-matching against FDA Philippines advisories. It is for informational '
            'purposes only and does not constitute an official FDA determination. To report '
            'a product, contact the FDA Philippines hotline listed at the end of this report.',
        style: pw.TextStyle(fontSize: 8.5, color: _warningText),
      ),
    );
  }

  static pw.Widget _sectionTitle(String title) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(title,
            style: pw.TextStyle(
                fontSize: 13,
                fontWeight: pw.FontWeight.bold,
                color: _text)),
        pw.SizedBox(height: 3),
        pw.Divider(color: _border, thickness: 0.8),
      ],
    );
  }

  static pw.Widget _overviewRow(
      int total, int compliant, int nonCompliant, int banned) {
    return pw.Row(
      children: [
        _statBox('Total Scanned', '$total', _text, _bg),
        pw.SizedBox(width: 8),
        _statBox('Compliant', '$compliant', _green, _greenBg),
        pw.SizedBox(width: 8),
        _statBox('Non-Compliant', '$nonCompliant', _amber, _amberBg),
        pw.SizedBox(width: 8),
        _statBox('Banned', '$banned', _red, _redBg),
      ],
    );
  }

  static pw.Widget _statBox(
      String label, String value, PdfColor textColor, PdfColor bgColor) {
    return pw.Expanded(
      child: pw.Container(
        padding: const pw.EdgeInsets.symmetric(vertical: 14, horizontal: 10),
        decoration: pw.BoxDecoration(
          color: bgColor,
          borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
          border: pw.Border.all(color: _border),
        ),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.center,
          children: [
            pw.Text(value,
                style: pw.TextStyle(
                    fontSize: 22,
                    fontWeight: pw.FontWeight.bold,
                    color: textColor)),
            pw.SizedBox(height: 4),
            pw.Text(label,
                style: pw.TextStyle(fontSize: 8.5, color: _muted),
                textAlign: pw.TextAlign.center),
          ],
        ),
      ),
    );
  }

  static pw.Widget _triggerTable(
      List<MapEntry<String, int>> triggers, int totalFlagged) {
    return pw.Table(
      border: pw.TableBorder.all(color: _border, width: 0.5),
      columnWidths: {
        0: const pw.FlexColumnWidth(3),
        1: const pw.FlexColumnWidth(1.5),
        2: const pw.FlexColumnWidth(1.5),
        3: const pw.FlexColumnWidth(1.5),
      },
      children: [
        // Header
        pw.TableRow(
          decoration: pw.BoxDecoration(color: _greenBg),
          children: [
            _tableCell('Keyword / Substance', header: true),
            _tableCell('Occurrences', header: true),
            _tableCell('% of Flagged', header: true),
            _tableCell('Status', header: true),
          ],
        ),
        ...triggers.map((e) {
          final pct = totalFlagged > 0
              ? '${(e.value / totalFlagged * 100).toStringAsFixed(0)}%'
              : '—';
          return pw.TableRow(children: [
            _tableCell(e.key),
            _tableCell('${e.value}'),
            _tableCell(pct),
            _tableCell('Flagged'),
          ]);
        }),
      ],
    );
  }

  static pw.Widget _flaggedTable(List<_Record> records) {
    return pw.Table(
      border: pw.TableBorder.all(color: _border, width: 0.5),
      columnWidths: {
        0: const pw.FlexColumnWidth(2.5),
        1: const pw.FlexColumnWidth(1.5),
        2: const pw.FlexColumnWidth(1.5),
        3: const pw.FlexColumnWidth(2.5),
      },
      children: [
        pw.TableRow(
          decoration: pw.BoxDecoration(color: _greenBg),
          children: [
            _tableCell('Product Name', header: true),
            _tableCell('Date Scanned', header: true),
            _tableCell('Status', header: true),
            _tableCell('Detection Basis', header: true),
          ],
        ),
        ...records.map((r) {
          final statusColor =
          r.status == 'WARNING / BANNED' ? _red : _amber;
          return pw.TableRow(children: [
            _tableCell(r.name),
            _tableCell(_fmtDate(r.date)),
            pw.Padding(
              padding: const pw.EdgeInsets.all(6),
              child: pw.Text(
                r.status == 'WARNING / BANNED' ? 'BANNED' : 'NON-COMPLIANT',
                style: pw.TextStyle(
                    fontSize: 8.5,
                    fontWeight: pw.FontWeight.bold,
                    color: statusColor),
              ),
            ),
            _tableCell(r.keyword),
          ]);
        }),
      ],
    );
  }

  static pw.Widget _compliantSection(List<_Record> records) {
    if (records.isEmpty) {
      return _emptyNote('No compliant records found.');
    }
    final names = records.map((r) => r.name).join(', ');
    return pw.Container(
      padding: const pw.EdgeInsets.all(10),
      decoration: pw.BoxDecoration(
        color: _greenBg,
        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
        border: pw.Border.all(color: _border),
      ),
      child: pw.Text(
        _pdfSafe('${records.length} product(s) classified as Compliant: $names'),
        style: pw.TextStyle(fontSize: 9, color: _green),
      ),
    );
  }

  static pw.Widget _hotlineFooter() {
    return pw.Container(
      padding: const pw.EdgeInsets.all(10),
      decoration: pw.BoxDecoration(
        color: _greenBg,
        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
        border: pw.Border.all(color: _border),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text('FDA Philippines',
              style: pw.TextStyle(
                  fontSize: 10,
                  fontWeight: pw.FontWeight.bold,
                  color: _green)),
          pw.SizedBox(height: 4),
          pw.Text(
            'Hotline: (02) 8807-0751  ·  Email: fdaphils@fda.gov.ph  ·  Site: www.fda.gov.ph\n'
                'If any product above is suspected to be dangerous or unregistered, please report it through the official FDA channel.',
            style: pw.TextStyle(fontSize: 8.5, color: _green),
          ),
        ],
      ),
    );
  }

  /// Every table cell carries record-supplied text (product names, matched
  /// keywords, the '-' placeholder for a missing field), so the ASCII fold
  /// belongs here rather than at each call site.
  static pw.Widget _tableCell(String text, {bool header = false}) {
    return pw.Padding(
      padding: const pw.EdgeInsets.all(6),
      child: pw.Text(
        _pdfSafe(text),
        style: pw.TextStyle(
          fontSize: 9,
          fontWeight: header ? pw.FontWeight.bold : pw.FontWeight.normal,
          color: _text,
        ),
      ),
    );
  }

  static pw.Widget _emptyNote(String msg) {
    return pw.Text(msg,
        style: pw.TextStyle(fontSize: 9, color: _muted));
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  /// Maps the typographic characters the app uses onto ASCII before they are
  /// drawn into the PDF.
  ///
  /// The pdf package's built-in Helvetica is a Latin-1 font with no Unicode
  /// coverage, so an em dash, en dash or multiplication sign silently draws
  /// as nothing — the record name reads "Dent 2" instead of "Dent x2", and a
  /// missing field renders as blank rather than a dash. Rather than bundle a
  /// full Unicode font just for four characters, fold them here; the on-screen
  /// text keeps the nicer glyphs.
  static String _pdfSafe(String s) => s
      .replaceAll('×', 'x') // multiplication sign
      .replaceAll('—', '-') // em dash
      .replaceAll('–', '-') // en dash
      .replaceAll('‘', "'")
      .replaceAll('’', "'")
      .replaceAll('“', '"')
      .replaceAll('”', '"');

  static String _fmtDate(DateTime dt) =>
      '${dt.year}-${_pad(dt.month)}-${_pad(dt.day)}';

  static String _fmtDatetime(DateTime dt) =>
      '${_fmtDate(dt)}  ${_pad(dt.hour)}:${_pad(dt.minute)}';

  static String _pad(int n) => n.toString().padLeft(2, '0');
}

// ── Internal model ────────────────────────────────────────────────────────────

/// One packaging photo that carries damage boxes, ready to draw.
class _Evidence {
  final String recordName;
  final DateTime date;
  final pw.MemoryImage image;

  /// Width / height of the embedded photo, used to give the drawn image a
  /// height that matches it so the normalised boxes land square on it.
  final double aspect;
  final List<DamageDetection> boxes;
  final String summary;
  final String packaging;

  const _Evidence({
    required this.recordName,
    required this.date,
    required this.image,
    required this.aspect,
    required this.boxes,
    required this.summary,
    required this.packaging,
  });
}

class _Record {
  final String name;
  final DateTime date;
  final String status;
  final String keyword;
  final Directory dir;

  /// The parsed record, or null if its data.json was missing or unreadable —
  /// the row still lists in the tables above from folder metadata alone.
  final ScanRecord? scan;

  const _Record({
    required this.name,
    required this.date,
    required this.status,
    required this.keyword,
    required this.dir,
    this.scan,
  });
}