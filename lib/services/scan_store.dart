import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

/// Saves and loads scan results alongside saved photos.
/// Each photo gets a matching .json file with the same base name.
class ScanStore {
  static String _jsonPath(String photoPath) {
    final dir = p.dirname(photoPath);
    final base = p.basenameWithoutExtension(photoPath);
    return p.join(dir, '$base.json');
  }

  static Future<void> save({
    required String photoPath,
    required String status,
    required String matchedKeyword,
    required String extractedText,
  }) async {
    final data = {
      'status': status,
      'matchedKeyword': matchedKeyword,
      'extractedText': extractedText,
      'scannedAt': DateTime.now().toIso8601String(),
    };
    await File(_jsonPath(photoPath))
        .writeAsString(jsonEncode(data));
  }

  static Map<String, dynamic>? load(String photoPath) {
    final f = File(_jsonPath(photoPath));
    if (!f.existsSync()) return null;
    try {
      return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  static void delete(String photoPath) {
    final f = File(_jsonPath(photoPath));
    if (f.existsSync()) f.deleteSync();
  }

  static Future<void> rename(String oldPath, String newPath) async {
    final oldJson = File(_jsonPath(oldPath));
    if (oldJson.existsSync()) {
      await oldJson.rename(_jsonPath(newPath));
    }
  }
}