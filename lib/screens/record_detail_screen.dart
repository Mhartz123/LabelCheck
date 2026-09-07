import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../models/scan_record.dart';
import '../services/scan_store.dart';
import '../theme/app_colors.dart';
import '../services/theme_controller.dart';
import '../widgets/damage_overlay.dart';

class RecordDetailScreen extends StatefulWidget {
  final Directory recordDir;
  const RecordDetailScreen({super.key, required this.recordDir});

  @override
  State<RecordDetailScreen> createState() => _RecordDetailScreenState();
}

class _RecordDetailScreenState extends State<RecordDetailScreen> {
  ScanRecord? _record;
  List<File> _photos = [];

  /// Packaging shots only, in the order [DamageDetection.sourceIndex] counts
  /// in. Kept alongside [_photos] (which leads with the label close-ups) so a
  /// photo can be matched back to the detections that came off it.
  List<File> _boxPhotos = [];
  int _mainPhotoIndex = 0;

  static const String _hotline = '1-800-CHK-MUNA';

  String _formatDate(DateTime dt) =>
      '${dt.year}-${_pad(dt.month)}-${_pad(dt.day)}  ${_pad(dt.hour)}:${_pad(dt.minute)}';
  String _pad(int n) => n.toString().padLeft(2, '0');

  @override
  void initState() {
    super.initState();
    _record = ScanStore.load(widget.recordDir);
    _photos = ScanStore.photosInOrder(widget.recordDir);
    _boxPhotos = ScanStore.boxPhotosInOrder(widget.recordDir);
  }

  /// The damage boxes belonging to [photo], or empty if it is a label
  /// close-up, carries no detections, or predates on-photo geometry.
  List<DamageDetection> _detectionsFor(File photo) {
    final record = _record;
    if (record == null || record.damageCheck.boxes.isEmpty) return const [];
    final index = _boxPhotos.indexWhere((f) => f.path == photo.path);
    if (index < 0) return const [];
    return record.damageCheck.boxes
        .where((d) => d.sourceIndex == index)
        .toList();
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

    return ListenableBuilder(
      listenable: ThemeController.instance,
      builder: (context, _) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final name = p.basename(widget.recordDir.path);
    final record = _record;

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        foregroundColor: AppColors.text,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleSpacing: 4,
        leadingWidth: 58,
        leading: _backButton(context),
        title: Text('Compliance Check',
            style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 19,
                color: AppColors.text)),
      ),
      body: record == null
          ? Center(
          child: Text('Record data not found.',
              style: TextStyle(color: AppColors.text)))
          : SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _hero(),
            if (_photos.length > 1) ...[
              const SizedBox(height: 12),
              _thumbnailStrip(),
            ],
            const SizedBox(height: 16),
            _resultCard(record, name),

            if (record.hasDamageData) ...[
              const SizedBox(height: 14),
              _damageCard(record),
            ],

            const SizedBox(height: 14),
            _hotlineCard(record),
          ],
        ),
      ),
    );
  }

  Widget _backButton(BuildContext context) {
    return Center(
      child: Material(
        color: AppColors.surface,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () => Navigator.of(context).maybePop(),
          child: SizedBox(
            width: 38,
            height: 38,
            child: Icon(Icons.chevron_left, size: 24, color: AppColors.text),
          ),
        ),
      ),
    );
  }

  Widget _hero() {
    return GestureDetector(
      onTap: () => _openFullscreen(_mainPhotoIndex),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: _photos.isEmpty
            ? Container(
          width: double.infinity,
          height: 210,
          color: AppColors.surfaceAlt,
          child: Icon(Icons.photo_camera_outlined,
              color: AppColors.muted, size: 44),
        )
            : Image.file(_photos[_mainPhotoIndex],
            width: double.infinity, height: 210, fit: BoxFit.cover),
      ),
    );
  }

  Widget _thumbnailStrip() {
    return SizedBox(
      height: 62,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _photos.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (context, i) {
          final selected = i == _mainPhotoIndex;
          return GestureDetector(
            onTap: () => setState(() => _mainPhotoIndex = i),
            onDoubleTap: () => _openFullscreen(i),
            child: Container(
              width: 62,
              height: 62,
              padding: EdgeInsets.all(selected ? 2 : 0),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: selected ? AppColors.accentLight : AppColors.border,
                  width: selected ? 2 : 1,
                ),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(selected ? 10 : 13),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.file(_photos[i], fit: BoxFit.cover),
                    // A dot marks the shots that actually have damage on
                    // them, so the strip says where to look without the
                    // user opening each one.
                    if (_detectionsFor(_photos[i]).isNotEmpty)
                      const Positioned(
                        top: 3,
                        right: 3,
                        child: Icon(Icons.error,
                            size: 13, color: Color(0xFFE65100)),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Color _bandColor(ScanRecord record) {
    switch (record.status) {
      case ComplianceStatus.compliant:
        return AppColors.compliantBg;
      case ComplianceStatus.nonCompliant:
        return AppColors.nonCompliantBg;
      case ComplianceStatus.banned:
        return AppColors.bannedBg;
    }
  }

  String _badgeText(ScanRecord record) {
    switch (record.status) {
      case ComplianceStatus.compliant:
        return 'FDA VERIFIED';
      case ComplianceStatus.nonCompliant:
        return 'NON-COMPLIANT';
      case ComplianceStatus.banned:
        return 'FDA BANNED';
    }
  }

  Widget _resultCard(ScanRecord record, String name) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border, width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [

          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: BoxDecoration(
              color: _bandColor(record),
              borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(17)),
            ),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: record.statusColor,
                  ),
                  child: Icon(record.statusIcon,
                      color: Colors.white, size: 19),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    record.statusTitle,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: record.statusColor,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: record.statusColor,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    _badgeText(record),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.4,
                    ),
                  ),
                ),
              ],
            ),
          ),

          Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [

                if (record.hasLabelData) ...[
                  _field('Product', record.productName),
                  _hairline(),
                  _field('Expiration', record.expiration),
                  _hairline(),
                  _field('Type', 'OTC Food Supplement'),
                  _hairline(),
                  _sectionLabel('INGREDIENTS'),
                  const SizedBox(height: 6),
                  Text(record.ingredients,
                      style: TextStyle(
                          fontSize: 13,
                          height: 1.45,
                          color: AppColors.text)),
                  const SizedBox(height: 12),
                  _hairline(),
                ],

                _field('Record', name),
                _hairline(),
                _field('Scanned', _formatDate(record.scannedAt)),
                const SizedBox(height: 14),

                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceAlt,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    record.note,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.45,
                      color: record.status == ComplianceStatus.compliant
                          ? AppColors.muted
                          : record.statusColor,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _field(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 11),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(fontSize: 13, color: AppColors.muted)),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                color: AppColors.text,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 11),
      child: Text(text,
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
            color: AppColors.muted,
          )),
    );
  }

  Widget _hairline() =>
      Container(height: 0.8, width: double.infinity, color: AppColors.border);

  Widget _damageCard(ScanRecord record) {
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
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border, width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _sectionLabel('PACKAGING / DAMAGE'),
              if (record.packagingType != null) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceAlt,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    record.packagingType!.label,
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      color: AppColors.muted,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(icon, size: 18, color: fg),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  unavailable
                      ? 'Check unavailable'
                      : damaged
                      ? 'Possible damage detected'
                      : 'No damage detected',
                  style: TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w700, color: fg),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(damage.message,
              style: TextStyle(fontSize: 12.5, height: 1.4, color: fg)),
          if (damaged && damage.detections.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text('Detections: ${damage.detectionSummary}',
                style: TextStyle(fontSize: 12, color: fg)),
          ],
          if (damaged)
            DamageEvidence(
              photos: _boxPhotos,
              detections: damage.boxes,
              foreground: fg,
            ),
        ],
      ),
    );
  }

  Widget _hotlineCard(ScanRecord record) {
    final compliant = record.status == ComplianceStatus.compliant;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border, width: 0.8),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: compliant ? AppColors.surfaceAlt : AppColors.bannedBg,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(Icons.call,
                size: 20,
                color: compliant ? AppColors.accent : record.statusColor),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('FDA HOTLINE',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8,
                      color: AppColors.muted,
                    )),
                const SizedBox(height: 3),
                Text(_hotline,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
                      color: AppColors.text,
                    )),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

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
