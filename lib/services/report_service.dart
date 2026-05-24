import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'fda_checker.dart';

/// Submits flagged (NON-COMPLIANT or BANNED) scan results to the
/// LabelCheck central dashboard.
///
/// Usage:
///   await ReportService.submit(
///     photoPath: destPath,
///     result: scanResult,
///     productName: fileName,
///   );
class ReportService {
  // ── CONFIGURE THIS ─────────────────────────────────────────────────────────
  // Replace with the URL where your dashboard is hosted.
  // If running locally for testing, use your machine's LAN IP, e.g.:
  //   http://192.168.1.100:8080/api/report
  static const String _endpoint = 'http://192.168.1.9:8080/api/report';

  // Set to false to disable image uploads (saves bandwidth).
  static const bool _includeImage = true;

  // Max image size in bytes to include in the payload (default 200 KB).
  static const int _maxImageBytes = 200 * 1024;
  // ─────────────────────────────────────────────────────────────────────────

  /// Submit a scan result. Only NON-COMPLIANT and WARNING/BANNED are sent.
  /// Returns true on success, false on failure or if status is not flagged.
  static Future<bool> submit({
    required String photoPath,
    required ScanResult result,
    required String productName,
  }) async {
    // Only send flagged results
    if (result.status == ComplianceStatus.compliant) return false;

    try {
      final payload = await _buildPayload(
        photoPath: photoPath,
        result: result,
        productName: productName,
      );

      final response = await http
          .post(
            Uri.parse(_endpoint),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 15));

      return response.statusCode == 200;
    } catch (e) {
      // Network errors are non-fatal — the scan is already saved locally.
      return false;
    }
  }

  static Future<Map<String, dynamic>> _buildPayload({
    required String photoPath,
    required ScanResult result,
    required String productName,
  }) async {
    String? imageBase64;

    if (_includeImage) {
      final file = File(photoPath);
      if (file.existsSync()) {
        final bytes = await file.readAsBytes();
        if (bytes.lengthInBytes <= _maxImageBytes) {
          imageBase64 = 'data:image/jpeg;base64,${base64Encode(bytes)}';
        }
      }
    }

    return {
      'id': '${DateTime.now().millisecondsSinceEpoch}_${productName.hashCode.abs()}',
      'productName': productName,
      'status': result.statusLabel,
      'matchedKeyword': result.matchedKeyword,
      'extractedText': result.extractedText,
      'scannedAt': DateTime.now().toIso8601String(),
      if (imageBase64 != null) 'imageBase64': imageBase64,
    };
  }
}
