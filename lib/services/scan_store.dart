import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../models/scan_record.dart';

/// Folder-per-record storage.
///
/// `UI_Prototype_Photos/<RecordName>/`
///   front.jpg          ┐
///   expiration.jpg     ├ label close-ups (OCR + FDA)
///   ingredients.jpg    ┘
///   box_front.jpg      ┐
///   box_side1.jpg      ├ box shots (YOLOv8 damage)
///   box_side2.jpg      │
///   box_back.jpg       ┘
///   data.json
///
/// There is intentionally no rename() — once a record is saved its name
/// cannot be changed, to prevent tampering with data that may already have
/// been submitted to the centralization dashboard.
class ScanStore {
  static const String rootFolderName = 'UI_Prototype_Photos';

  static Future<Directory> rootDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(appDir.path, rootFolderName));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Sanitizes a raw user-entered name into a safe folder name.
  static String sanitizeName(String raw) {
    var name = raw.trim().replaceAll(' ', '_');
    name = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    return name;
  }

  static Future<bool> recordExists(String rawName) async {
    if (rawName.trim().isEmpty) return false;
    final root = await rootDir();
    final dir = Directory(p.join(root.path, sanitizeName(rawName)));
    return dir.existsSync();
  }

  /// Creates `<root>/<sanitized name>/`, copies each captured temp photo
  /// into its slot filename, writes data.json. Returns the created
  /// record directory.
  static Future<Directory> save({
    required String rawName,
    required Map<PhotoSlot, String> capturedPhotoPaths,
    required Map<BoxSlot, String> boxPhotoPaths,
    required ScanRecord record,
  }) async {
    final root = await rootDir();
    final name = sanitizeName(rawName);
    final dir = Directory(p.join(root.path, name));
    await dir.create(recursive: true);

    for (final entry in capturedPhotoPaths.entries) {
      final destPath = p.join(dir.path, '${entry.key.fileBaseName}.jpg');
      await File(entry.value).copy(destPath);
    }

    for (final entry in boxPhotoPaths.entries) {
      final destPath = p.join(dir.path, '${entry.key.fileBaseName}.jpg');
      await File(entry.value).copy(destPath);
    }

    final jsonFile = File(p.join(dir.path, 'data.json'));
    await jsonFile.writeAsString(jsonEncode(record.toJson()));

    return dir;
  }

  /// Lists all record folders under root (unsorted — caller sorts).
  static Future<List<Directory>> listRecordDirs() async {
    final root = await rootDir();
    if (!root.existsSync()) return [];
    return root.listSync().whereType<Directory>().toList();
  }

  static ScanRecord? load(Directory recordDir) {
    final jsonFile = File(p.join(recordDir.path, 'data.json'));
    if (!jsonFile.existsSync()) return null;
    try {
      final map = jsonDecode(jsonFile.readAsStringSync()) as Map<String, dynamic>;
      return ScanRecord.fromJson(map);
    } catch (_) {
      return null;
    }
  }

  /// Returns whichever slot photos exist in [recordDir], label close-ups
  /// first (Front/Expiration/Ingredients) then box shots (Front/Side/Side/Back).
  /// Missing (skipped) slots are omitted.
  static List<File> photosInOrder(Directory recordDir) {
    const labelOrder = [
      PhotoSlot.front,
      PhotoSlot.expiration,
      PhotoSlot.ingredients,
    ];
    const boxOrder = [
      BoxSlot.front,
      BoxSlot.side1,
      BoxSlot.side2,
      BoxSlot.back,
    ];
    final result = <File>[];
    for (final slot in labelOrder) {
      final f = File(p.join(recordDir.path, '${slot.fileBaseName}.jpg'));
      if (f.existsSync()) result.add(f);
    }
    for (final slot in boxOrder) {
      final f = File(p.join(recordDir.path, '${slot.fileBaseName}.jpg'));
      if (f.existsSync()) result.add(f);
    }
    return result;
  }

  static Future<void> delete(Directory recordDir) async {
    if (await recordDir.exists()) {
      await recordDir.delete(recursive: true);
    }
  }
}
