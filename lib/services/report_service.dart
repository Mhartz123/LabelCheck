import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../models/scan_record.dart';
import 'scan_store.dart';

/// Submits scan results to the CheckMuna central dashboard hosted on
/// Vercel + Supabase.
///
/// Every saved scan is submitted, not just flagged ones — the dashboard needs
/// clean results too, otherwise it can't show how many boxes came back
/// undamaged or what share of labels passed.
///
/// The payload mirrors [ScanRecord.kind]: a label scan carries the label
/// block, a damage scan carries the damage block, and an inspection scan
/// ([ScanKind.both]) carries both. The server splits these across its
/// `report_label_checks` / `report_damage_checks` tables accordingly.
///
/// Setup:
///   1. Deploy the website folder to Vercel (see its README.md)
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
      'https://label-check-website.vercel.app/api/report';

  // Set to false to disable image uploads (saves bandwidth / Supabase storage).
  static const bool _includeImage = true;

  // Max image size in bytes included in the payload (default 200 KB).
  static const int _maxImageBytes = 200 * 1024;
  // ─────────────────────────────────────────────────────────────────────────

  /// Submit a scan result. Returns true on success, false on any failure.
  /// Network errors are non-fatal — the scan is already saved on the device,
  /// so a failed submit only means the dashboard misses this row.
  static Future<bool> submit({
    required Directory recordDir,
    required ScanRecord record,
    required String productName,
  }) async {
    // Skip if endpoint hasn't been configured yet
    if (_endpoint.contains('YOUR_PROJECT_NAME')) {
      return false;
    }

    try {
      final payload = await _buildPayload(
        recordDir: recordDir,
        record: record,
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
    required Directory recordDir,
    required ScanRecord record,
    required String productName,
  }) async {
    String? imageBase64;

    if (_includeImage) {
      final photos = ScanStore.photosInOrder(recordDir);
      if (photos.isNotEmpty) {
        final bytes = await photos.first.readAsBytes();
        if (bytes.lengthInBytes <= _maxImageBytes) {
          imageBase64 = 'data:image/jpeg;base64,${base64Encode(bytes)}';
        }
      }
    }

    final damage = record.damageCheck;

    return {
      'id': '${DateTime.now().millisecondsSinceEpoch}_${productName.hashCode.abs()}',
      // Which check(s) this record represents — drives how the server splits
      // the blocks below across its per-check tables.
      'kind': record.kind.name,
      // Null for a label-only scan; the packaging the damage step ran against.
      'packagingType': record.packagingType?.name,
      // The name the user saved the record under.
      'productName': productName,
      'status': record.statusLabel,
      'matchedKeyword': record.matchedKeyword,
      'reasons': record.reasons,
      'scannedAt': record.scannedAt.toIso8601String(),
      if (imageBase64 != null) 'imageBase64': imageBase64,

      // ── Label block — omitted entirely for a damage-only scan ──
      if (record.hasLabelData)
        'label': {
          // What OCR read off the front label, as opposed to productName
          // above which is the user's own record name.
          'detectedProductName': record.productName,
          'expiration': record.expiration,
          'ingredients': record.ingredients,
          'extractedText': record.extractedText,
        },

      // ── Damage block — omitted entirely for a label-only scan ──
      if (record.hasDamageData)
        'damage': {
          'available': damage.available,
          'message': damage.message,
          'isDamaged': damage.isDamaged,
          // Per-detection class names, e.g. ['Dent', 'Dent', 'Scratches'].
          'detections': damage.detections,
          // Same detections with geometry: normalised 0..1 rect on the source
          // photo, per-detection confidence, and which packaging shot it came
          // from. Lets the dashboard redraw the overlay the app showed.
          'boxes': damage.boxes.map((b) => b.toJson()).toList(),
          'maxConfidence': damage.maxConfidence,
        },
    };
  }
}
