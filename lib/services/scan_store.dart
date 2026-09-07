import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../models/scan_record.dart';
import 'app_storage.dart';

/// Folder-per-record storage.
///
/// `CheckMuna/records/<RecordName>/`
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
  /// The folder layout is owned by [AppStorage], which also migrates records
  /// saved under the old `UI_Prototype_Photos` name.
  static Future<Directory> rootDir() => AppStorage.recordsDir();

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
  static List<File> photosInOrder(Directory recordDir) => [
    ..._existing(recordDir, _labelOrder.map((s) => s.fileBaseName)),
    ...boxPhotosInOrder(recordDir),
  ];

  /// Just the packaging shots, in [BoxSlot] order with skipped slots omitted.
  ///
  /// This is the list [DamageDetection.sourceIndex] indexes into. It matches
  /// the order the camera screen hands photos to the damage detector — both
  /// walk the slots in declaration order and drop the ones never captured —
  /// so index *n* here is the photo that produced detection index *n*.
  /// Keep the two in step if you ever add or reorder a [BoxSlot].
  static List<File> boxPhotosInOrder(Directory recordDir) =>
      _existing(recordDir, _boxOrder.map((s) => s.fileBaseName));

  static const _labelOrder = [
    PhotoSlot.front,
    PhotoSlot.expiration,
    PhotoSlot.ingredients,
  ];

  static const _boxOrder = [
    BoxSlot.front,
    BoxSlot.side1,
    BoxSlot.side2,
    BoxSlot.back,
  ];

  static List<File> _existing(Directory recordDir, Iterable<String> baseNames) {
    final result = <File>[];
    for (final base in baseNames) {
      final f = File(p.join(recordDir.path, '$base.jpg'));
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
