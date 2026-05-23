import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'record_detail_screen.dart';
import '../../services/scan_store.dart';

class RecordsScreen extends StatefulWidget {
  const RecordsScreen({super.key});

  @override
  State<RecordsScreen> createState() => RecordsScreenState();
}

class RecordsScreenState extends State<RecordsScreen> {
  List<File> _allFiles = [];
  List<File> _filtered = [];
  String _sortBy = 'Name';
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
      final Directory? extDir = await getExternalStorageDirectory();
      final String rootPath = extDir!.path.split('Android').first;
      final Directory photoDir =
      Directory(p.join(rootPath, 'Pictures', 'VeriFyDA'));
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
          .where((f) => p
          .basename(f.path)
          .toLowerCase()
          .contains(_searchQuery.toLowerCase()))
          .toList();
    }
    if (_sortBy == 'Name') {
      list.sort((a, b) =>
          p.basename(a.path).compareTo(p.basename(b.path)));
    } else if (_sortBy == 'Date') {
      list.sort((a, b) =>
          b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    }
    // Compliance sort is non-functional for now
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Records - Mode',
            style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        elevation: 1,
        centerTitle: true,
      ),
      backgroundColor: Colors.white,
      body: Column(
        children: [
          // Sort bar
          Padding(
            padding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                const Text('Sort By :',
                    style: TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w500)),
                const SizedBox(width: 8),
                _SortChip(
                    label: 'Name',
                    selected: _sortBy == 'Name',
                    onTap: () => _onSortChanged('Name')),
                const SizedBox(width: 6),
                _SortChip(
                    label: 'Date',
                    selected: _sortBy == 'Date',
                    onTap: () => _onSortChanged('Date')),
                const SizedBox(width: 6),
                _SortChip(
                    label: 'Compliance',
                    selected: _sortBy == 'Compliance',
                    onTap: () => _onSortChanged('Compliance')),
              ],
            ),
          ),

          // Search bar
          Padding(
            padding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: TextField(
              onChanged: _onSearchChanged,
              decoration: InputDecoration(
                hintText: '.jpeg',
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 10),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8)),
                suffixIcon:
                const Icon(Icons.search, color: Colors.grey),
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
                      size: 64, color: Colors.grey.shade400),
                  const SizedBox(height: 12),
                  Text('No records yet',
                      style: TextStyle(
                          fontSize: 16,
                          color: Colors.grey.shade500)),
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
              color: Colors.white,
              padding: const EdgeInsets.symmetric(
                  horizontal: 20, vertical: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton.icon(
                    onPressed: _unselectAll,
                    icon: const Icon(Icons.check_box_outline_blank,
                        color: Colors.black54),
                    label: const Text('Unselect All',
                        style: TextStyle(color: Colors.black54)),
                  ),
                  ElevatedButton.icon(
                    onPressed: _confirmMultiDelete,
                    icon: const Icon(Icons.close, color: Colors.white),
                    label: const Text('Delete All',
                        style: TextStyle(color: Colors.white)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFE57373),
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

  const _SortChip(
      {required this.label,
        required this.selected,
        required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding:
        const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xFFE57373)
              : Colors.grey.shade200,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: selected ? Colors.white : Colors.black87,
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

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onSelect,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: Colors.grey.shade100,
          borderRadius: BorderRadius.circular(12),
          border: isSelected
              ? Border.all(color: const Color(0xFF4CAF50), width: 2)
              : null,
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Date row
              Text('Date : ${_formatDate(date)}',
                  style: const TextStyle(
                      fontSize: 12, color: Colors.black54)),
              const SizedBox(height: 6),

              // Name row with delete + checkbox
              Row(
                children: [
                  const Text('Name : ',
                      style: TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600)),
                  Expanded(
                    child: GestureDetector(
                      onTap: onRename,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: Colors.grey.shade300),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(name,
                                  style: const TextStyle(fontSize: 12),
                                  overflow: TextOverflow.ellipsis),
                            ),
                            Icon(Icons.edit, size: 12, color: Colors.grey.shade400),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  // Red X delete
                  GestureDetector(
                    onTap: onDelete,
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: const Color(0xFFE57373),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Icon(Icons.close,
                          color: Colors.white, size: 16),
                    ),
                  ),
                  const SizedBox(width: 6),
                  // Checkbox for multi-select
                  GestureDetector(
                    onTap: onSelect,
                    child: Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                            color: Colors.grey.shade400, width: 1.5),
                        color: isSelected
                            ? const Color(0xFF4CAF50)
                            : Colors.white,
                      ),
                      child: isSelected
                          ? const Icon(Icons.check,
                          size: 14, color: Colors.white)
                          : null,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),

              // Compliance — reads from saved JSON
              Builder(builder: (_) {
                final data = ScanStore.load(file.path);
                final status = data?['status'] as String? ?? '—';
                final keyword = data?['matchedKeyword'] as String? ?? '—';

                Color statusColor = Colors.grey;
                if (status == 'COMPLIANT') statusColor = const Color(0xFF4CAF50);
                if (status == 'NON-COMPLIANT') statusColor = const Color(0xFFFF9800);
                if (status == 'WARNING / BANNED') statusColor = const Color(0xFFF44336);

                return Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.grey.shade200),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Text('Compliance Status : ',
                              style: TextStyle(fontSize: 12)),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: statusColor,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              status,
                              style: const TextStyle(
                                  fontSize: 11,
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text('Detection Basis    : $keyword',
                          style: const TextStyle(
                              fontSize: 12, color: Colors.black54),
                          overflow: TextOverflow.ellipsis),
                    ],
                  ),
                );
              }),
            ],
          ),
        ),
      ),
    );
  }
}