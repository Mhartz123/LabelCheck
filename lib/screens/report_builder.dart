import 'dart:io';
import 'package:flutter/material.dart' show Color, Colors;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import '../services/scan_store.dart';

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

  /// Loads all photos + their sidecar JSON files and builds the PDF.
  /// Returns the in-memory PDF bytes ready for [Printing.layoutPdf].
  static Future<pw.Document> build() async {
    final dir = await _photoDir();
    final files = _loadAllFiles(dir);
    final records = _parseRecords(files);
    return _buildDocument(records);
  }

  // ── File loading ─────────────────────────────────────────────────────────

  static Future<Directory> _photoDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    return Directory(p.join(appDir.path, 'UI_Prototype_Photos'));
  }

  static List<File> _loadAllFiles(Directory dir) {
    if (!dir.existsSync()) return [];
    return dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.jpeg') || f.path.endsWith('.jpg'))
        .toList()
      ..sort((a, b) =>
          b.lastModifiedSync().compareTo(a.lastModifiedSync()));
  }

  static List<_Record> _parseRecords(List<File> files) {
    return files.map((f) {
      final data = ScanStore.load(f.path);
      return _Record(
        name: p.basenameWithoutExtension(f.path),
        date: f.lastModifiedSync(),
        status: data?['status'] as String? ?? '—',
        keyword: data?['matchedKeyword'] as String? ?? '—',
        file: f,
      );
    }).toList();
  }

  // ── PDF construction ──────────────────────────────────────────────────────

  static pw.Document _buildDocument(List<_Record> records) {
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
    final earliest = dates.isNotEmpty ? _fmtDate(dates.first) : '—';
    final latest = dates.isNotEmpty ? _fmtDate(dates.last) : '—';
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
            pw.Text('Generated by VerifyDA',
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
            'VerifyDA',
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
              pw.Text('Period: $earliest – $latest',
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
        'This report is generated by VerifyDA based on automated label scanning and '
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
        '${records.length} product(s) classified as Compliant: $names',
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

  static pw.Widget _tableCell(String text, {bool header = false}) {
    return pw.Padding(
      padding: const pw.EdgeInsets.all(6),
      child: pw.Text(
        text,
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

  static String _fmtDate(DateTime dt) =>
      '${dt.year}-${_pad(dt.month)}-${_pad(dt.day)}';

  static String _fmtDatetime(DateTime dt) =>
      '${_fmtDate(dt)}  ${_pad(dt.hour)}:${_pad(dt.minute)}';

  static String _pad(int n) => n.toString().padLeft(2, '0');
}

// ── Internal model ────────────────────────────────────────────────────────────

class _Record {
  final String name;
  final DateTime date;
  final String status;
  final String keyword;
  final File file;

  const _Record({
    required this.name,
    required this.date,
    required this.status,
    required this.keyword,
    required this.file,
  });
}