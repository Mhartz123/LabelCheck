import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../models/scan_record.dart';
import '../services/scan_store.dart';
import '../theme/app_colors.dart';

class RecordDetailScreen extends StatefulWidget {
  final Directory recordDir;
  const RecordDetailScreen({super.key, required this.recordDir});

  @override
  State<RecordDetailScreen> createState() => _RecordDetailScreenState();
}

class _RecordDetailScreenState extends State<RecordDetailScreen> {
  ScanRecord? _record;
  List<File> _photos = [];
  int _mainPhotoIndex = 0;

  String _formatDate(DateTime dt) =>
      '${dt.year}-${_pad(dt.month)}-${_pad(dt.day)}  ${_pad(dt.hour)}:${_pad(dt.minute)}';
  String _pad(int n) => n.toString().padLeft(2, '0');

  @override
  void initState() {
    super.initState();
    _record = ScanStore.load(widget.recordDir);
    _photos = ScanStore.photosInOrder(widget.recordDir);
  }

  void _openFullscreen(int index) {
    if (_photos.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _FullscreenPhotoViewer(
          photos: _photos,
          initialIndex: index,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final name = p.basename(widget.recordDir.path);
    final record = _record;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Compliance Check',
            style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        elevation: 1,
        centerTitle: true,
      ),
      backgroundColor: Colors.white,
      body: record == null
          ? const Center(child: Text('Record data not found.'))
          : SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Main product photo
            GestureDetector(
              onTap: () => _openFullscreen(_mainPhotoIndex),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: _photos.isEmpty
                    ? Container(
                  width: double.infinity,
                  height: 240,
                  color: Colors.grey.shade200,
                  child: Icon(Icons.image_not_supported_outlined,
                      color: Colors.grey.shade400, size: 48),
                )
                    : Image.file(_photos[_mainPhotoIndex],
                    width: double.infinity, height: 240, fit: BoxFit.cover),
              ),
            ),

            if (_photos.length > 1) ...[
              const SizedBox(height: 10),
              SizedBox(
                height: 64,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _photos.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (context, i) => GestureDetector(
                    onTap: () => setState(() => _mainPhotoIndex = i),
                    onDoubleTap: () => _openFullscreen(i),
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: i == _mainPhotoIndex
                              ? AppColors.accentLight
                              : AppColors.border,
                          width: i == _mainPhotoIndex ? 2 : 1,
                        ),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(7),
                        child: Image.file(_photos[i],
                            width: 64, height: 64, fit: BoxFit.cover),
                      ),
                    ),
                  ),
                ),
              ),
            ],

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
                      Text(record.statusTitle,
                          style: TextStyle(
                              color: record.statusColor,
                              fontWeight: FontWeight.bold,
                              fontSize: 16)),
                      Container(
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                            color: record.statusColor,
                            borderRadius: BorderRadius.circular(4)),
                      ),
                    ],
                  ),
                  const Divider(height: 20),
                  _row('Product', record.productName),
                  const SizedBox(height: 4),
                  _row('Expiration', record.expiration),
                  const SizedBox(height: 4),
                  _row('Type', 'OTC Food Supplement'),
                  const Divider(height: 20),
                  Text('INGREDIENTS',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: AppColors.muted)),
                  const SizedBox(height: 4),
                  Text(record.ingredients,
                      style: const TextStyle(fontSize: 13)),
                  const Divider(height: 20),
                  _row('Name', name),
                  const SizedBox(height: 4),
                  _row('Date', _formatDate(record.scannedAt)),
                  const Divider(height: 20),
                  Text('Note : ${record.note}',
                      style:
                      TextStyle(fontSize: 12, color: record.noteColor)),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // ── Packaging / box damage (separate YOLOv8 box-photo step) ──
            Text('PACKAGING / BOX DAMAGE',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: AppColors.muted)),
            const SizedBox(height: 6),
            _damageBlock(record),
            const SizedBox(height: 16),

            // FDA Hotline
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                  horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.grey.shade300),
              ),
              child: Text(
                'FDA Hotline : ${record.status == ComplianceStatus.compliant ? 'XXX-XXXX-XXX' : 'XXX-XXXX-XXX'}',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: record.status == ComplianceStatus.compliant
                      ? Colors.black87
                      : const Color(0xFFE57373),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value) {
    return Text('$label : $value', style: const TextStyle(fontSize: 13));
  }

  Widget _damageBlock(ScanRecord record) {
    final damage = record.damageCheck;
    final unavailable = !damage.available;
    final damaged = damage.isDamaged;

    final Color fg = damaged
        ? const Color(0xFFC62828)
        : unavailable
            ? AppColors.muted
            : const Color(0xFF2E7D32);
    final IconData icon = unavailable
        ? Icons.help_outline
        : damaged
            ? Icons.warning_amber_rounded
            : Icons.check_circle_outline;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: fg),
              const SizedBox(width: 8),
              Text(
                unavailable
                    ? 'Check unavailable'
                    : damaged
                        ? 'Possible damage detected'
                        : 'No damage detected',
                style: TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600, color: fg),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(damage.message,
              style: TextStyle(fontSize: 12, color: fg)),
          if (damaged && damage.detections.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text('Detections: ${damage.detections.toSet().join(', ')}',
                style: TextStyle(fontSize: 12, color: fg)),
          ],
        ],
      ),
    );
  }
}

// ── Fullscreen photo viewer ─────────────────────────────────────────────────

class _FullscreenPhotoViewer extends StatelessWidget {
  final List<File> photos;
  final int initialIndex;

  const _FullscreenPhotoViewer({
    required this.photos,
    required this.initialIndex,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: PageView.builder(
        controller: PageController(initialPage: initialIndex),
        itemCount: photos.length,
        itemBuilder: (context, i) => InteractiveViewer(
          minScale: 1,
          maxScale: 4,
          child: Center(
            child: Image.file(photos[i], fit: BoxFit.contain),
          ),
        ),
      ),
    );
  }
}
