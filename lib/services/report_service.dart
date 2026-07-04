import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'fda_checker.dart';

/// Submits flagged (NON-COMPLIANT or BANNED) scan results to the
/// LabelCheck central dashboard hosted on Vercel + Supabase.
///
/// Setup:
///   1. Deploy the server folder to Vercel (see README.md in server folder)
///   2. Replace _endpoint below with your actual Vercel URL
///   3. Make sure SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are set
///      in Vercel Project Settings → Environment Variables
class ReportService {
  // ── CONFIGURE THIS ─────────────────────────────────────────────────────────
  // Replace with your actual Vercel deployment URL, e.g.:
  //   https://your-project-name.vercel.app/api/report
  //
  // DO NOT use http://localhost or a LAN IP here — those only work
  // when the server is running on the same network.
  static const String _endpoint =
      'https://label-check-website.vercel.app/';

  // Set to false to disable image uploads (saves bandwidth / Supabase storage).
  static const bool _includeImage = true;

  // Max image size in bytes included in the payload (default 200 KB).
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

    // Skip if endpoint hasn't been configured yet
    if (_endpoint.contains('YOUR_PROJECT_NAME')) {
      return false;
    }

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