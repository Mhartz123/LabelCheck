import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'record_detail_screen.dart';
import '../services/scan_store.dart';
import '../models/scan_record.dart';
import '../theme/app_colors.dart';
import '../widgets/theme_toggle_button.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import '../services/report_builder.dart';

class RecordsScreen extends StatefulWidget {
  const RecordsScreen({super.key});

  @override
  State<RecordsScreen> createState() => RecordsScreenState();
}

class RecordsScreenState extends State<RecordsScreen> {
  List<Directory> _allDirs = [];
  List<Directory> _filtered = [];
  String _sortBy = 'Name';
  bool _nameAscending = true;
  bool _dateNewest = true;
  String _complianceFilter = '';
  String _searchQuery = '';
  final Set<String> _selected = {};
  bool _isSelecting = false;
  bool _loading = true;

  static const List<String> _kindCycle = ['Label', 'Damage', 'Inspect'];
  String _kindFilterLabel = 'Label';

  @override
  void initState() {
    super.initState();
    loadFiles();
  }

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> loadFiles() async {
    setState(() => _loading = true);
    try {
      _allDirs = await ScanStore.listRecordDirs();
      _applySort();
    } catch (e) {
      debugPrint('Load files error: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  ScanKind get _kindFilterValue {
    switch (_kindFilterLabel) {
      case 'Damage':
        return ScanKind.damage;
      case 'Inspect':
        return ScanKind.both;
      default:
        return ScanKind.label;
    }
  }

  Color get _kindFilterColor {
    switch (_kindFilterLabel) {
      case 'Damage':
        return AppColors.damageKind;
      case 'Inspect':
        return AppColors.inspection;
      default:
        return AppColors.labelKind;
    }
  }

  void _cycleKindFilter() {
    final idx = _kindCycle.indexOf(_kindFilterLabel);
    setState(() => _kindFilterLabel = _kindCycle[(idx + 1) % _kindCycle.length]);
    _applySort();
  }

  void _applySort() {
    List<Directory> list = List.from(_allDirs);
    if (_searchQuery.isNotEmpty) {
      list = list
          .where((d) => p.basename(d.path)
          .toLowerCase()
          .contains(_searchQuery.toLowerCase()))
          .toList();
    }
    list = list.where((d) {
      final record = ScanStore.load(d);
      return record?.kind == _kindFilterValue;
    }).toList();
    if (_complianceFilter.isNotEmpty) {
      list = list.where((d) {
        final record = ScanStore.load(d);
        return record?.statusLabel == _complianceFilter;
      }).toList();
    }
    if (_sortBy == 'Name') {
      list.sort((a, b) => _nameAscending
          ? p.basename(a.path).compareTo(p.basename(b.path))
          : p.basename(b.path).compareTo(p.basename(a.path)));
    } else if (_sortBy == 'Date') {
      list.sort((a, b) {
        final aDate = ScanStore.load(a)?.scannedAt ?? a.statSync().modified;
        final bDate = ScanStore.load(b)?.scannedAt ?? b.statSync().modified;
        return _dateNewest ? bDate.compareTo(aDate) : aDate.compareTo(bDate);
      });
    }
    setState(() => _filtered = list);
  }

  void _onSearchChanged(String val) {
    _searchQuery = val;
    _applySort();
  }

  void _toggleSelect(String path) {
    setState(() {
      if (_selected.contains(path)) {
        _selected.remove(path);
      } else {
        _selected.add(path);
      }
      _isSelecting = _selected.isNotEmpty;
    });
  }

  void _unselectAll() {
    setState(() {
      _selected.clear();
      _isSelecting = false;
    });
  }

  void _selectAll() {
    setState(() {
      _selected.addAll(_filtered.map((d) => d.path));
      _isSelecting = _selected.isNotEmpty;
    });
  }

  void _confirmSingleDelete(Directory dir) {
    _showDeleteSheet(
      title: 'Delete record',
      subtitle: 'Are you sure you want to delete this record?',
      note: 'This permanently removes the record — all its photos and data '
          '— from the app and from phone storage. It cannot be undone.',
      confirmLabel: 'Delete',
      onConfirm: () async {
        await ScanStore.delete(dir);
        loadFiles();
      },
    );
  }

  void _confirmMultiDelete() {
    final count = _selected.length;
    _showDeleteSheet(
      title: 'Delete $count record${count == 1 ? '' : 's'}',
      subtitle: 'Are you sure you want to delete the selected '
          'record${count == 1 ? '' : 's'}?',
      note: 'This permanently removes them — all their photos and data — '
          'from the app and from phone storage. It cannot be undone.',
      confirmLabel: 'Delete all',
      onConfirm: () async {
        for (final path in _selected) {
          await ScanStore.delete(Directory(path));
        }
        _unselectAll();
        loadFiles();
      },
    );
  }

  void _showDeleteSheet({
    required String title,
    required String subtitle,
    required String note,
    required String confirmLabel,
    required Future<void> Function() onConfirm,
  }) {
    showModalBottomSheet(
      context: context,

      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: AppColors.bannedBg,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.delete_outline,
                      color: AppColors.bannedText, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(title,
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                            color: AppColors.text,
                          )),
                      const SizedBox(height: 2),
                      Text(subtitle,
                          style: TextStyle(
                            fontSize: 12.5,
                            color: AppColors.muted,
                          )),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.bannedBg,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.warning_amber_rounded,
                      size: 16, color: AppColors.bannedText),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      note,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.4,
                        color: AppColors.bannedText,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.text,
                      backgroundColor: AppColors.surface,
                      side: BorderSide(color: AppColors.border),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                      padding: const EdgeInsets.symmetric(vertical: 15),
                    ),
                    child: const Text('Cancel',
                        style: TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w600)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () async {
                      Navigator.of(context).pop();
                      await onConfirm();
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFC62828),
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                      padding: const EdgeInsets.symmetric(vertical: 15),
                    ),
                    child: Text(confirmLabel,
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _generateReport() async {

    showDialog(
      context: context,
      barrierDismissible: false,

      builder: (_) => Center(
        child: CircularProgressIndicator(color: AppColors.accentLight),
      ),
    );

    try {
      final pw.Document pdf = await ReportBuilder.build();
      if (!mounted) return;
      Navigator.of(context).pop();

      await Printing.layoutPdf(
        onLayout: (_) async => pdf.save(),
        name: 'CheckMuna_Compliance_Report_${DateTime.now().millisecondsSinceEpoch}.pdf',
      );
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to generate report: $e'),
          backgroundColor: AppColors.bannedText,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(

        titleSpacing: 16,
        title: Text('Records',
            style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: AppColors.text)),
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.text,
        elevation: 0,
        centerTitle: false,

        toolbarHeight: 56,

        shape: Border(
          bottom: BorderSide(color: AppColors.border, width: 0.6),
        ),
        actions: [

          ThemeToggleButton(),

          Padding(
            padding: const EdgeInsets.only(right: 10, top: 8, bottom: 8),
            child: Material(
              color: AppColors.accent,
              borderRadius: BorderRadius.circular(10),
              child: InkWell(
                onTap: _generateReport,
                borderRadius: BorderRadius.circular(10),
                child: const Padding(
                  padding:
                  EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.picture_as_pdf_outlined,
                          color: Colors.white, size: 16),
                      SizedBox(width: 6),
                      Text('PDF',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          )),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      backgroundColor: AppColors.bg,
      body: Column(
        children: [

          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text('Sort :',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                    const SizedBox(width: 8),
                    _SortChip(
                        label: _sortBy == 'Name'
                            ? (_nameAscending ? 'Name A→Z' : 'Name Z→A')
                            : 'Name A→Z',
                        selected: _sortBy == 'Name',
                        onTap: () {
                          if (_sortBy == 'Name') {
                            setState(() => _nameAscending = !_nameAscending);
                          } else {
                            setState(() { _sortBy = 'Name'; _nameAscending = true; });
                          }
                          _applySort();
                        }),
                    const SizedBox(width: 6),
                    _SortChip(
                        label: _sortBy == 'Date'
                            ? (_dateNewest ? 'Date Latest' : 'Date Oldest')
                            : 'Date Latest',
                        selected: _sortBy == 'Date',
                        onTap: () {
                          if (_sortBy == 'Date') {
                            setState(() => _dateNewest = !_dateNewest);
                          } else {
                            setState(() { _sortBy = 'Date'; _dateNewest = true; });
                          }
                          _applySort();
                        }),
                    const SizedBox(width: 6),

                    _CycleFilterChip(
                      label: _kindFilterLabel,
                      color: _kindFilterColor,
                      onTap: _cycleKindFilter,
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      const Text('Filter :',
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                      const SizedBox(width: 8),
                      _SortChip(
                          label: 'Compliant',
                          selected: _complianceFilter == 'COMPLIANT',
                          color: const Color(0xFF4CAF50),
                          onTap: () {
                            setState(() => _complianceFilter =
                            _complianceFilter == 'COMPLIANT' ? '' : 'COMPLIANT');
                            _applySort();
                          }),
                      const SizedBox(width: 6),
                      _SortChip(
                          label: 'Non-Compliant',
                          selected: _complianceFilter == 'NON-COMPLIANT',
                          color: const Color(0xFFFF9800),
                          onTap: () {
                            setState(() => _complianceFilter =
                            _complianceFilter == 'NON-COMPLIANT' ? '' : 'NON-COMPLIANT');
                            _applySort();
                          }),
                      const SizedBox(width: 6),
                      _SortChip(
                          label: 'Banned',
                          selected: _complianceFilter == 'WARNING / BANNED',
                          color: const Color(0xFFF44336),
                          onTap: () {
                            setState(() => _complianceFilter =
                            _complianceFilter == 'WARNING / BANNED' ? '' : 'WARNING / BANNED');
                            _applySort();
                          }),
                    ],
                  ),
                ),
              ],
            ),
          ),

          Padding(
            padding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: TextField(
              onChanged: _onSearchChanged,

              style: TextStyle(fontSize: 13, color: AppColors.text),
              decoration: InputDecoration(
                hintText: 'Search by name',
                hintStyle: TextStyle(color: AppColors.muted, fontSize: 13),
                isDense: true,
                filled: true,
                fillColor: AppColors.surface,
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: AppColors.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: AppColors.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),

                  borderSide: BorderSide(color: AppColors.accentLight, width: 1.5),
                ),
                suffixIcon:
                Icon(Icons.search, color: AppColors.muted),
              ),
            ),
          ),
          const SizedBox(height: 4),

          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _filtered.isEmpty
                ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.folder_open,
                      size: 64, color: AppColors.muted),
                  const SizedBox(height: 12),
                  Text('No records yet',
                      style: TextStyle(
                          fontSize: 16,
                          color: AppColors.muted)),
                ],
              ),
            )
                : RefreshIndicator(
              onRefresh: loadFiles,
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 8),
                itemCount: _filtered.length,
                itemBuilder: (context, index) {
                  final dir = _filtered[index];
                  final name = p.basename(dir.path);
                  final record = ScanStore.load(dir);
                  final date = record?.scannedAt ?? dir.statSync().modified;
                  final isSelected =
                  _selected.contains(dir.path);

                  return _RecordCard(
                    dir: dir,
                    name: name,
                    date: date,
                    isSelected: isSelected,
                    isSelecting: _isSelecting,
                    onTap: () {
                      if (_isSelecting) {
                        _toggleSelect(dir.path);
                      } else {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => RecordDetailScreen(
                                recordDir: dir),
                          ),
                        );
                      }
                    },
                    onDelete: () => _confirmSingleDelete(dir),
                    onSelect: () => _toggleSelect(dir.path),
                  );
                },
              ),
            ),
          ),

          AnimatedSize(
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: !_isSelecting
                ? const SizedBox(width: double.infinity)
                : AnimatedSlide(
              offset: _isSelecting ? Offset.zero : const Offset(0, 1),
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeOutCubic,
              child: AnimatedOpacity(
                opacity: _isSelecting ? 1 : 0,
                duration: const Duration(milliseconds: 180),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 12),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    border: Border(
                        top: BorderSide(
                            color: AppColors.border, width: 0.6)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      TextButton.icon(
                        onPressed: _selectAll,

                        icon: Icon(Icons.select_all, color: AppColors.muted),

                        label: Text('Select All',
                            style: TextStyle(color: AppColors.muted)),
                      ),
                      TextButton.icon(
                        onPressed: _unselectAll,

                        icon: Icon(Icons.check_box_outline_blank,
                            color: AppColors.muted),

                        label: Text('Unselect All',
                            style: TextStyle(color: AppColors.muted)),
                      ),
                      ElevatedButton.icon(
                        onPressed: _confirmMultiDelete,
                        icon: const Icon(Icons.close, color: Colors.white),
                        label: const Text('Delete All',
                            style: TextStyle(color: Colors.white)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.bannedText,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SortChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Color? color;

  const _SortChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final activeColor = color ?? AppColors.accentLight;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? activeColor : AppColors.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? activeColor : AppColors.border,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: selected ? Colors.white : AppColors.muted,
          ),
        ),
      ),
    );
  }
}

class _CycleFilterChip extends StatelessWidget {
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _CycleFilterChip({
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.sync, size: 12, color: Colors.white),
            const SizedBox(width: 4),
            Text(
              label,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RecordCard extends StatelessWidget {
  final Directory dir;
  final String name;
  final DateTime date;
  final bool isSelected;
  final bool isSelecting;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final VoidCallback onSelect;

  const _RecordCard({
    required this.dir,
    required this.name,
    required this.date,
    required this.isSelected,
    required this.isSelecting,
    required this.onTap,
    required this.onDelete,
    required this.onSelect,
  });

  String _formatDate(DateTime dt) =>
      '${dt.year} / ${_pad(dt.month)} / ${_pad(dt.day)}';
  String _pad(int n) => n.toString().padLeft(2, '0');

  ({IconData icon, Color bg, Color fg, Color pillBg, Color pillText}) _statusVisuals(
      String status) {
    switch (status) {
      case 'COMPLIANT':
        return (
        icon: Icons.check,
        bg: AppColors.compliantBg,
        fg: AppColors.compliantText,
        pillBg: AppColors.compliantBg,
        pillText: AppColors.compliantText,
        );
      case 'NON-COMPLIANT':
        return (
        icon: Icons.warning_amber_rounded,
        bg: AppColors.nonCompliantBg,
        fg: AppColors.nonCompliantText,
        pillBg: AppColors.nonCompliantBg,
        pillText: AppColors.nonCompliantText,
        );
      case 'WARNING / BANNED':
        return (
        icon: Icons.block,
        bg: AppColors.bannedBg,
        fg: AppColors.bannedText,
        pillBg: AppColors.bannedBg,
        pillText: AppColors.bannedText,
        );
      default:
        return (
        icon: Icons.image_outlined,
        bg: AppColors.surfaceAlt,
        fg: AppColors.muted,
        pillBg: AppColors.surfaceAlt,
        pillText: AppColors.muted,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final record = ScanStore.load(dir);
    final status = record?.statusLabel ?? '—';
    final keyword = record?.matchedKeyword ?? '—';
    final packagingType = record?.packagingType;
    final visuals = _statusVisuals(status);

    return GestureDetector(
      onTap: onTap,
      onLongPress: onSelect,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isSelected ? AppColors.accentLight : AppColors.border,
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [

              Container(
                width: 44,
                height: 44,
                margin: const EdgeInsets.only(top: 2),
                decoration: BoxDecoration(
                  color: visuals.bg,
                  shape: BoxShape.circle,
                ),
                child: Icon(visuals.icon, color: visuals.fg, size: 21),
              ),
              const SizedBox(width: 12),

              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [

                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            name,

                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: AppColors.text,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),

                        GestureDetector(
                          onTap: onDelete,
                          child: Container(
                            width: 28,
                            height: 28,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: AppColors.bannedBg,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Icon(Icons.close,
                                color: AppColors.bannedText, size: 16),
                          ),
                        ),

                        const SizedBox(width: 10),

                        GestureDetector(
                          onTap: onSelect,
                          child: Container(
                            width: 26,
                            height: 26,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                  color: AppColors.border, width: 1.5),
                              color: isSelected
                                  ? AppColors.accentLight
                                  : AppColors.surface,
                            ),
                            child: isSelected
                                ? const Icon(Icons.check,
                                size: 15, color: Colors.white)
                                : null,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),

                    Text(
                      _formatDate(date),

                      style: TextStyle(
                          fontSize: 11.5, color: AppColors.muted),
                    ),
                    const SizedBox(height: 8),

                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: visuals.pillBg,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            status,
                            style: TextStyle(
                              fontSize: 10.5,
                              color: visuals.pillText,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        if (packagingType != null) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: AppColors.surfaceAlt,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              packagingType.label,

                              style: TextStyle(
                                fontSize: 10.5,
                                color: AppColors.muted,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (keyword != '—') ...[
                      const SizedBox(height: 5),
                      Text(
                        'Detection basis: $keyword',

                        style: TextStyle(
                            fontSize: 11.5, color: AppColors.muted),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),

              const SizedBox(width: 4),
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Icon(Icons.chevron_right,
                    size: 18, color: AppColors.muted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
