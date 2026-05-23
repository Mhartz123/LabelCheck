import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../../services/scan_store.dart';

enum ComplianceStatus { compliant, nonCompliant, banned, unknown }

extension ComplianceStatusExtension on ComplianceStatus {
  String get label {
    switch (this) {
      case ComplianceStatus.compliant: return 'Compliant';
      case ComplianceStatus.nonCompliant: return 'Non-Compliant';
      case ComplianceStatus.banned: return 'Banned';
      case ComplianceStatus.unknown: return '—';
    }
  }

  Color get color {
    switch (this) {
      case ComplianceStatus.compliant: return const Color(0xFF4CAF50);
      case ComplianceStatus.nonCompliant: return const Color(0xFFFFEB3B);
      case ComplianceStatus.banned: return const Color(0xFFE57373);
      case ComplianceStatus.unknown: return Colors.grey;
    }
  }

  String get note {
    switch (this) {
      case ComplianceStatus.compliant:
        return 'Product is compliant with the FDA and is safe to consume. Please refer to instructions / professionals with regards to safe dosage.';
      case ComplianceStatus.nonCompliant:
        return 'Product is non-compliant with the FDA and is inadvisable to consume. Please refer to the local FDA hotline near you to report this occurrence.';
      case ComplianceStatus.banned:
        return 'Product is banned by the FDA, dangerous to consume. Please immediately refer to the local FDA hotline near you to report this occurrence.';
      case ComplianceStatus.unknown:
        return 'Compliance data not yet available.';
    }
  }

  Color get noteColor {
    switch (this) {
      case ComplianceStatus.compliant: return Colors.black54;
      case ComplianceStatus.nonCompliant:
      case ComplianceStatus.banned: return const Color(0xFFE57373);
      case ComplianceStatus.unknown: return Colors.black54;
    }
  }
}

class RecordDetailScreen extends StatefulWidget {
  final File file;
  const RecordDetailScreen({super.key, required this.file});

  @override
  State<RecordDetailScreen> createState() => _RecordDetailScreenState();
}

class _RecordDetailScreenState extends State<RecordDetailScreen> {
  ComplianceStatus _status = ComplianceStatus.unknown;
  String _productType = '—';
  double? _confidence;
  bool _isChecking = false;

  String _formatDate(DateTime dt) =>
      '${dt.year}-${_pad(dt.month)}-${_pad(dt.day)}  ${_pad(dt.hour)}:${_pad(dt.minute)}';
  String _pad(int n) => n.toString().padLeft(2, '0');

  @override
  void initState() {
    super.initState();
    _loadSavedResult(); // load on open
  }

  void _loadSavedResult() {
    final data = ScanStore.load(widget.file.path);
    if (data != null) {
      final statusStr = data['status'] as String? ?? '';
      setState(() {
        _status = _statusFromString(statusStr);
        _productType = 'OTC Food Supplement';
        _confidence = 1.0; // keyword match = 100% confidence
      });
    }
  }

  ComplianceStatus _statusFromString(String s) {
    if (s == 'COMPLIANT') return ComplianceStatus.compliant;
    if (s == 'WARNING / BANNED') return ComplianceStatus.banned;
    if (s == 'NON-COMPLIANT') return ComplianceStatus.nonCompliant;
    return ComplianceStatus.unknown;
  }

  Future<void> _runComplianceCheck() async {
    setState(() => _isChecking = true);
    await Future.delayed(const Duration(milliseconds: 500));
    _loadSavedResult();
    setState(() => _isChecking = false);
  }

  @override
  Widget build(BuildContext context) {
    final name = p.basenameWithoutExtension(widget.file.path);
    final date = widget.file.lastModifiedSync();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Compliance Check', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        elevation: 1,
        centerTitle: true,
      ),
      backgroundColor: Colors.white,
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Product image
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.file(widget.file, width: double.infinity, height: 240, fit: BoxFit.cover),
            ),
            const SizedBox(height: 16),

            // Info card
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.grey.shade300),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('FDA Status : ${_status.label}', style: const TextStyle(fontSize: 13)),
                          const SizedBox(height: 4),
                          Text('Product Type : $_productType', style: const TextStyle(fontSize: 13)),
                          const SizedBox(height: 4),
                          Text('Confidence : ${_confidence != null ? _confidence!.toStringAsFixed(2) : '—'}', style: const TextStyle(fontSize: 13)),
                        ],
                      ),
                      Container(
                        width: 24, height: 24,
                        decoration: BoxDecoration(color: _status.color, borderRadius: BorderRadius.circular(4)),
                      ),
                    ],
                  ),
                  const Divider(height: 20),
                  Text('Name : $name', style: const TextStyle(fontSize: 13)),
                  const SizedBox(height: 4),
                  Text('Date : ${_formatDate(date)}', style: const TextStyle(fontSize: 13)),
                  const Divider(height: 20),
                  Text('Note : ${_status.note}', style: TextStyle(fontSize: 12, color: _status.noteColor)),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // FDA Hotline
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.grey.shade300),
              ),
              child: Text(
                'FDA Hotline : ${_status == ComplianceStatus.unknown ? '—' : 'XXX-XXXX-XXX'}',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: _status == ComplianceStatus.compliant ? Colors.black87 : const Color(0xFFE57373),
                ),
              ),
            ),
            const SizedBox(height: 20),

            // Check button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _isChecking ? null : _runComplianceCheck,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF4CAF50),
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: Colors.grey.shade300,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: _isChecking
                    ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('Run Compliance Check', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}