import 'dart:io';

import 'package:flutter/material.dart';
import '../models/scan_record.dart';
import '../theme/app_colors.dart';
import '../services/theme_controller.dart';
import '../widgets/damage_overlay.dart';

class ResultScreen extends StatelessWidget {
  final ScanRecord record;

  /// The packaging photos this scan ran against, in [BoxSlot] order — the same
  /// order [DamageDetection.sourceIndex] counts in. Supplied straight from the
  /// camera screen because the record hasn't been saved to disk yet at this
  /// point, so there is no record folder to read them back from. Empty for a
  /// label-only scan, which simply shows no damage evidence.
  final List<String> boxPhotoPaths;

  const ResultScreen({
    super.key,
    required this.record,
    this.boxPhotoPaths = const [],
  });

  String get _title {
    switch (record.kind) {
      case ScanKind.label:
        return 'Label Scan Result';
      case ScanKind.damage:
        return 'Packaging / Damage Result';
      case ScanKind.both:
        return 'Inspection Result';
    }
  }

  @override
  Widget build(BuildContext context) {

    return ListenableBuilder(
      listenable: ThemeController.instance,
      builder: (context, _) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final isCompliant = record.status == ComplianceStatus.compliant;
    final isBanned = record.status == ComplianceStatus.banned;

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: Text(_title,
            style: TextStyle(
                fontWeight: FontWeight.w600, color: AppColors.text)),
        backgroundColor: AppColors.bg,
        foregroundColor: AppColors.text,
        elevation: 0,
        centerTitle: false,
      ),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [

                  Center(
                    child: Column(
                      children: [
                        Container(
                          width: 72,
                          height: 72,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: record.statusColor,
                          ),
                          child: Icon(record.statusIcon,
                              color: Colors.white, size: 34),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'LABEL COMPLIANCE',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.0,
                            color: AppColors.muted,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          record.statusLabel,
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: record.statusColor,
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 20),

                  if (!isCompliant && record.reasons.isNotEmpty)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: isBanned
                            ? AppColors.bannedBg
                            : AppColors.nonCompliantBg,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.warning_amber_rounded,
                                color: isBanned
                                    ? AppColors.bannedText
                                    : AppColors.nonCompliantText,
                                size: 18,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                isBanned
                                    ? "Why it's flagged"
                                    : "Why it's non-compliant",
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13.5,
                                  color: isBanned
                                      ? AppColors.bannedText
                                      : AppColors.nonCompliantText,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          for (final reason in record.reasons)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Text('•  $reason',
                                  style: TextStyle(
                                      fontSize: 13, color: AppColors.text)),
                            ),
                        ],
                      ),
                    ),

                  if (!isCompliant && record.reasons.isNotEmpty)
                    const SizedBox(height: 20),

                  if (record.hasLabelData) ...[
                    Container(
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(14),
                        border:
                        Border.all(color: AppColors.border, width: 0.6),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _cardField('PRODUCT', record.productName,
                              emphasize: true),
                          Divider(
                              height: 1, color: AppColors.border),
                          _cardField('EXPIRATION', record.expiration),
                          Divider(
                              height: 1, color: AppColors.border),
                          _cardField('INGREDIENT LIST', record.ingredients,
                              boxed: true),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],

                  if (record.hasDamageData) ...[
                    if (record.hasLabelData) const Divider(height: 1),
                    if (record.hasLabelData) const SizedBox(height: 16),
                    Row(
                      children: [
                        Text('Packaging / damage',
                            style: TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 14, color: AppColors.text)),
                        if (record.packagingType != null) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: AppColors.surfaceAlt,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              record.packagingType!.label,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: AppColors.muted,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 8),
                    _DamageSection(
                      damage: record.damageCheck,
                      boxPhotoPaths: boxPhotoPaths,
                    ),
                  ],
                ],
              ),
            ),
          ),

          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.refresh, size: 20),
                label: const Text('Scan Again',
                    style: TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF15916B),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _cardField(String label, String value,
      {bool emphasize = false, bool boxed = false}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
                  color: AppColors.muted)),
          const SizedBox(height: 4),
          if (boxed)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.surfaceAlt,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(value,
                  style: TextStyle(fontSize: 13, color: AppColors.text)),
            )
          else
            Text(value,
                style: TextStyle(
                    fontSize: emphasize ? 16 : 13.5,
                    fontWeight:
                    emphasize ? FontWeight.bold : FontWeight.normal,
                    color: AppColors.text)),
        ],
      ),
    );
  }
}

class _DamageSection extends StatelessWidget {
  final DamageCheckResult damage;
  final List<String> boxPhotoPaths;

  const _DamageSection({
    required this.damage,
    this.boxPhotoPaths = const [],
  });

  @override
  Widget build(BuildContext context) {
    final unavailable = !damage.available;
    final damaged = damage.isDamaged;

    final Color bg = damaged
        ? AppColors.nonCompliantBg
        : unavailable
        ? AppColors.surfaceAlt
        : const Color(0xFFE8F5E9);
    final Color fg = damaged
        ? AppColors.nonCompliantText
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
        color: bg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: fg),
              const SizedBox(width: 8),
              Text(
                unavailable
                    ? 'Check unavailable'
                    : damaged
                    ? 'Possible damage detected'
                    : 'No damage detected',
                style: TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 13.5, color: fg),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            damage.message,
            style: TextStyle(fontSize: 12.5, color: fg),
          ),
          if (damaged && damage.detections.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              'Detections: ${damage.detectionSummary}',
              style: TextStyle(fontSize: 12, color: fg),
            ),
          ],
          if (damage.isDamaged)
            DamageEvidence(
              photos: boxPhotoPaths.map(File.new).toList(),
              detections: damage.boxes,
              foreground: fg,
            ),
        ],
      ),
    );
  }


}
