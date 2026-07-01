import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'record_detail_screen.dart';
import '../services/scan_store.dart';
import '../theme/app_colors.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import '../screens/report_builder.dart';

class RecordsScreen extends StatefulWidget {
  const RecordsScreen({super.key});

  @override
  State<RecordsScreen> createState() => RecordsScreenState();
}

class RecordsScreenState extends State<RecordsScreen> {
  List<File> _allFiles = [];
  List<File> _filtered = [];
  String _sortBy = 'Name';
  bool _nameAscending = true;
  bool _dateNewest = true;
  String _complianceFilter = '';
  String _searchQuery = '';
  final Set<String> _selected = {};
  bool _isSelecting = false;
  bool _loading = true;

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
      final Directory appDir = await getApplicationDocumentsDirectory();
      final Directory photoDir = Directory(p.join(appDir.path, 'UI_Prototype_Photos'));
      if (!await photoDir.exists()) {
        setState(() {
          _allFiles = [];
          _filtered = [];
          _loading = false;
        });
        return;
      }
      final files = photoDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.jpeg') || f.path.endsWith('.jpg'))
          .toList();
      _allFiles = files;
      _applySort();
    } catch (e) {
      debugPrint('Load files error: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _applySort() {
    List<File> list = List.from(_allFiles);
    if (_searchQuery.isNotEmpty) {
      list = list
          .where((f) => p.basename(f.path).toLowerCase().contains(_searchQuery.toLowerCase()))
          .toList();
    }
    if (_complianceFilter.isNotEmpty) {
      list = list.where((f) {
        final data = ScanStore.load(f.path);
        final status = data?['status'] as String? ?? '';
        return status == _complianceFilter;
      }).toList();
    }
    if (_sortBy == 'Name') {
      list.sort((a, b) => _nameAscending
          ? p.basename(a.path).compareTo(p.basename(b.path))
          : p.basename(b.path).compareTo(p.basename(a.path)));
    } else if (_sortBy == 'Date') {
      list.sort((a, b) => _dateNewest
          ? b.lastModifiedSync().compareTo(a.lastModifiedSync())
          : a.lastModifiedSync().compareTo(b.lastModifiedSync()));
    }
    setState(() => _filtered = list);
  }

  void _onSearchChanged(String val) {
    _searchQuery = val;
    _applySort();
  }

  void _onSortChanged(String val) {
    _sortBy = val;
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
      _selected.addAll(_filtered.map((f) => f.path));
      _isSelecting = _selected.isNotEmpty;
    });
  }

  // ── Rename ───────────────────────────────────────────────────────────────
  Future<bool> _nameExists(String fileName, String excludePath) async {
    final dir = File(excludePath).parent;
    final candidate = File(p.join(dir.path, fileName));
    return candidate.existsSync() && candidate.path != excludePath;
  }

  void _confirmRename(File file) {
    final currentName = p.basenameWithoutExtension(file.path);
    final TextEditingController nameController =
    TextEditingController(text: currentName);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        bool isTaken = false;
        bool isEmpty = false;

        return StatefulBuilder(
          builder: (context, setSheetState) {
            void onChanged(String val) async {
              final newFileName = val.trim().endsWith('.jpeg')
                  ? val.trim()
                  : '${val.trim()}.jpeg';
              final taken = val.trim().isEmpty
                  ? false
                  : await _nameExists(newFileName, file.path);
              setSheetState(() {
                isTaken = taken;
                isEmpty = val.trim().isEmpty;
              });
            }

            return Padding(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 20,
                bottom: MediaQuery.of(context).viewInsets.bottom + 20,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Title bar
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFD4A847),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text(
                      'User Instruction - Rename Record',
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 14),
                    ),
                  ),
                  const SizedBox(height: 14),
                  // Input
                  TextField(
                    controller: nameController,
                    autofocus: true,
                    onChanged: onChanged,
                    decoration: InputDecoration(
                      hintText: 'Enter new name',
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(
                          color: isTaken
                              ? const Color(0xFFE57373)
                              : Colors.grey.shade400,
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(
                          color: isTaken
                              ? const Color(0xFFE57373)
                              : const Color(0xFF4CAF50),
                          width: 2,
                        ),
                      ),
                      errorText: isTaken
                          ? 'This name is already taken. Please choose another.'
                          : null,
                      errorStyle: const TextStyle(
                          color: Color(0xFFE57373), fontSize: 11),
                      errorBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide:
                        const BorderSide(color: Color(0xFFE57373)),
                      ),
                      focusedErrorBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(
                            color: Color(0xFFE57373), width: 2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text('Current name: $currentName.jpeg',
                      style: const TextStyle(
                          fontSize: 11, color: Colors.black45)),
                  const SizedBox(height: 20),
                  // Buttons
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton(
                          onPressed: () => Navigator.of(context).pop(),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFE57373),
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10)),
                            padding:
                            const EdgeInsets.symmetric(vertical: 14),
                          ),
                          child: const Text('Cancel',
                              style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.bold)),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: (isEmpty || isTaken)
                              ? null
                              : () async {
                            final raw =
                            nameController.text.trim();
                            Navigator.of(context).pop();
                            await _renameFile(file, raw);
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF4CAF50),
                            foregroundColor: Colors.white,
                            disabledBackgroundColor:
                            Colors.grey.shade300,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10)),
                            padding:
                            const EdgeInsets.symmetric(vertical: 14),
                          ),
                          child: const Text('Confirm',
                              style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.bold)),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _renameFile(File file, String newName) async {
    try {
      String newFileName =
      newName.endsWith('.jpeg') ? newName : '$newName.jpeg';
      newFileName = newFileName.replaceAll(' ', '_');
      final String newPath =
      p.join(file.parent.path, newFileName);

      // Rename JSON sidecar first
      await ScanStore.rename(file.path, newPath);

      await file.rename(newPath);
      loadFiles();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Renamed to "$newFileName"'),
            backgroundColor: const Color(0xFF4CAF50),
          ),
        );
      }
    } catch (e) {
      debugPrint('Rename error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to rename file.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // Single delete confirmation
  void _confirmSingleDelete(File file) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: double.infinity,
              padding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFFD4A847),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                'User Instruction - Delete Record',
                style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 14),
              ),
            ),
            const SizedBox(height: 14),
            const Text('Are you sure you want to delete this file?',
                style: TextStyle(fontSize: 14)),
            const SizedBox(height: 8),
            const Text(
              '*Note : Deleting this file will permanently remove it from the app records and phone storage.',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
            const SizedBox(height: 6),
            const Text('Are you really sure?',
                style: TextStyle(fontSize: 12, color: Colors.black54)),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF4CAF50),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: const Text('Cancel',
                        style: TextStyle(
                            fontSize: 15, fontWeight: FontWeight.bold)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () async {
                      Navigator.of(context).pop();
                      ScanStore.delete(file.path); // delete JSON sidecar
                      await file.delete();
                      loadFiles();
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFE57373),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: const Text('Delete',
                        style: TextStyle(
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

  // Multi delete confirmation
  void _confirmMultiDelete() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: double.infinity,
              padding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFFD4A847),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                'User Instruction - Delete Records',
                style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 14),
              ),
            ),
            const SizedBox(height: 14),
            const Text('Are you sure you want to delete selected files?',
                style: TextStyle(fontSize: 14)),
            const SizedBox(height: 8),
            const Text(
              '*Note : Deleting these files will permanently remove it from the app records and phone storage.',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
            const SizedBox(height: 6),
            const Text('Are you really sure?',
                style: TextStyle(fontSize: 12, color: Colors.black54)),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF4CAF50),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: const Text('Cancel',
                        style: TextStyle(
                            fontSize: 15, fontWeight: FontWeight.bold)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () async {
                      Navigator.of(context).pop();
                      for (final path in _selected) {
                        ScanStore.delete(path); // delete JSON sidecar
                        await File(path).delete();
                      }
                      _unselectAll();
                      loadFiles();
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFE57373),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: const Text('Delete',
                        style: TextStyle(
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

  // ── Generate PDF report ───────────────────────────────────────────────────
  Future<void> _generateReport() async {
    // Show loading indicator
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
        child: CircularProgressIndicator(color: AppColors.accentLight),
      ),
    );

    try {
      final pw.Document pdf = await ReportBuilder.build();
      if (!mounted) return;
      Navigator.of(context).pop(); // dismiss loading

      // Open the built-in PDF preview (includes share + print buttons)
      await Printing.layoutPdf(
        onLayout: (_) async => pdf.save(),
        name: 'VerifyDA_Compliance_Report_${DateTime.now().millisecondsSinceEpoch}.pdf',
      );
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop(); // dismiss loading
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
        title: const Text('Records',
            style: TextStyle(fontWeight: FontWeight.w600, color: AppColors.text)),
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.text,
        elevation: 0,
        centerTitle: true,
        shape: const Border(
          bottom: BorderSide(color: AppColors.border, width: 0.6),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.picture_as_pdf_outlined),
            tooltip: 'Generate Report',
            onPressed: _generateReport,
          ),
        ],
      ),
      backgroundColor: AppColors.bg,
      body: Column(
        children: [
          // Sort bar
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

          // Search bar
          Padding(
            padding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: TextField(
              onChanged: _onSearchChanged,
              style: const TextStyle(fontSize: 13, color: AppColors.text),
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
                  borderSide: const BorderSide(color: AppColors.accentLight, width: 1.5),
                ),
                suffixIcon:
                Icon(Icons.search, color: AppColors.muted),
              ),
            ),
          ),
          const SizedBox(height: 4),

          // File list
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
                  final file = _filtered[index];
                  final name =
                  p.basenameWithoutExtension(file.path);
                  final date = file.lastModifiedSync();
                  final isSelected =
                  _selected.contains(file.path);

                  return _RecordCard(
                    file: file,
                    name: name,
                    date: date,
                    isSelected: isSelected,
                    isSelecting: _isSelecting,
                    onTap: () {
                      if (_isSelecting) {
                        _toggleSelect(file.path);
                      } else {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => RecordDetailScreen(
                                file: file),
                          ),
                        );
                      }
                    },
                    onDelete: () => _confirmSingleDelete(file),
                    onSelect: () => _toggleSelect(file.path),
                    onRename: () => _confirmRename(file),
                  );
                },
              ),
            ),
          ),

          // Multi-select bottom bar
          if (_isSelecting)
            Container(
              color: AppColors.surface,
              padding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 12),
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: AppColors.border, width: 0.6)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton.icon(
                    onPressed: _selectAll,
                    icon: const Icon(Icons.select_all, color: AppColors.muted),
                    label: const Text('Select All',
                        style: TextStyle(color: AppColors.muted)),
                  ),
                  TextButton.icon(
                    onPressed: _unselectAll,
                    icon: const Icon(Icons.check_box_outline_blank,
                        color: AppColors.muted),
                    label: const Text('Unselect All',
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
        ],
      ),
    );
  }
}

// ── Sort chip ────────────────────────────────────────────────────────────────

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

// ── Record card ──────────────────────────────────────────────────────────────

class _RecordCard extends StatelessWidget {
  final File file;
  final String name;
  final DateTime date;
  final bool isSelected;
  final bool isSelecting;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final VoidCallback onSelect;
  final VoidCallback onRename;

  const _RecordCard({
    required this.file,
    required this.name,
    required this.date,
    required this.isSelected,
    required this.isSelecting,
    required this.onTap,
    required this.onDelete,
    required this.onSelect,
    required this.onRename,
  });

  String _formatDate(DateTime dt) =>
      '${dt.year} / ${_pad(dt.month)} / ${_pad(dt.day)}';
  String _pad(int n) => n.toString().padLeft(2, '0');

  // Maps the saved status string to icon + colors for the leading circle.
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
    final data = ScanStore.load(file.path);
    final status = data?['status'] as String? ?? '—';
    final keyword = data?['matchedKeyword'] as String? ?? '—';
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
              // Status icon circle — leading visual indicator
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

              // Main content column
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Name row with rename + delete + checkbox
                    Row(
                      children: [
                        Expanded(
                          child: GestureDetector(
                            onTap: onRename,
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    name,
                                    style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color: AppColors.text,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Icon(Icons.edit,
                                    size: 13, color: AppColors.muted),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        // Delete button
                        GestureDetector(
                          onTap: onDelete,
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              color: AppColors.bannedBg,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Icon(Icons.close,
                                color: AppColors.bannedText, size: 14),
                          ),
                        ),
                        const SizedBox(width: 6),
                        // Multi-select checkbox
                        GestureDetector(
                          onTap: onSelect,
                          child: Container(
                            width: 20,
                            height: 20,
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
                                size: 12, color: Colors.white)
                                : null,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),

                    // Date
                    Text(
                      _formatDate(date),
                      style: const TextStyle(
                          fontSize: 11.5, color: AppColors.muted),
                    ),
                    const SizedBox(height: 8),

                    // Compliance pill + detection basis
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
                      ],
                    ),
                    if (keyword != '—') ...[
                      const SizedBox(height: 5),
                      Text(
                        'Detection basis: $keyword',
                        style: const TextStyle(
                            fontSize: 11.5, color: AppColors.muted),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),

              // Trailing chevron to signal tappability
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