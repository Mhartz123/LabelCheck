import 'package:flutter/material.dart';

class HomeScreen extends StatelessWidget {
  final VoidCallback onGetStarted;

  const HomeScreen({super.key, required this.onGetStarted});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(
          children: [
            // ── Header ──────────────────────────────────────────────────────
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(24, 32, 24, 28),
              decoration: const BoxDecoration(
                color: Color(0xFF4CAF50),
                borderRadius: BorderRadius.vertical(bottom: Radius.circular(28)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: const Icon(Icons.qr_code_scanner,
                            color: Color(0xFF4CAF50), size: 28),
                      ),
                      const SizedBox(width: 12),
                      const Text(
                        'VerifyDA',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'Welcome!',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 30,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Learn how to use the app before getting started.',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.88),
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),

            // ── How it works ────────────────────────────────────────────────
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'How it works',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF1A1A1A),
                      ),
                    ),
                    const SizedBox(height: 16),
                    _Step(
                      number: '1',
                      icon: Icons.camera_alt_outlined,
                      title: 'Take a photo',
                      description:
                          'Point your camera at a food supplement label and tap the shutter button to capture it.',
                    ),
                    _Step(
                      number: '2',
                      icon: Icons.drive_file_rename_outline,
                      title: 'Name your scan',
                      description:
                          'After taking the photo, give it a unique name so you can find it easily in your records later.',
                    ),
                    _Step(
                      number: '3',
                      icon: Icons.fact_check_outlined,
                      title: 'Check compliance',
                      description:
                          'Open a record and tap the compliance check. The app scans the label text and tells you if the product is Compliant, Non-Compliant, or Banned.',
                    ),
                    _Step(
                      number: '4',
                      icon: Icons.folder_outlined,
                      title: 'Manage your records',
                      description:
                          'View, sort, rename, or delete your saved scans any time from the Records tab.',
                    ),
                    const SizedBox(height: 24),

                    // ── Compliance legend ──────────────────────────────────
                    const Text(
                      'Compliance indicators',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF1A1A1A),
                      ),
                    ),
                    const SizedBox(height: 12),
                    _ComplianceLegendItem(
                      color: const Color(0xFF4CAF50),
                      label: 'Compliant',
                      description:
                          'Product is registered and safe to consume. Follow instructions for proper dosage.',
                    ),
                    _ComplianceLegendItem(
                      color: const Color(0xFFFF9800),
                      label: 'Non-Compliant',
                      description:
                          'Product does not meet FDA standards. Inadvisable to consume — report to the local FDA hotline.',
                    ),
                    _ComplianceLegendItem(
                      color: const Color(0xFFE57373),
                      label: 'Banned / Warning',
                      description:
                          'Product is banned by the FDA. Dangerous to consume. Report immediately to the local FDA hotline.',
                    ),
                    const SizedBox(height: 24),

                    // ── FDA Hotline ───────────────────────────────────────
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF5F5F5),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: const Color(0xFFE0E0E0)),
                      ),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: const Color(0xFF4CAF50).withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Icon(Icons.phone_outlined,
                                color: Color(0xFF4CAF50), size: 22),
                          ),
                          const SizedBox(width: 14),
                          const Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('FDA Philippines Hotline',
                                  style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: Color(0xFF1A1A1A))),
                              SizedBox(height: 2),
                              Text('(02) 8807-0751',
                                  style: TextStyle(
                                      fontSize: 13, color: Color(0xFF555555))),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // ── Get Started button ───────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: onGetStarted,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF4CAF50),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                    elevation: 0,
                  ),
                  child: const Text(
                    'Get Started',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Step widget ───────────────────────────────────────────────────────────────

class _Step extends StatelessWidget {
  final String number;
  final IconData icon;
  final String title;
  final String description;

  const _Step({
    required this.number,
    required this.icon,
    required this.title,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Step number circle
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: const Color(0xFF4CAF50),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Center(
              child: Text(
                number,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                ),
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFFF9F9F9),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFEEEEEE)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(icon, size: 18, color: const Color(0xFF4CAF50)),
                      const SizedBox(width: 8),
                      Text(
                        title,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF1A1A1A),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    description,
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF666666),
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Compliance legend item ────────────────────────────────────────────────────

class _ComplianceLegendItem extends StatelessWidget {
  final Color color;
  final String label;
  final String description;

  const _ComplianceLegendItem({
    required this.color,
    required this.label,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 14,
            height: 14,
            margin: const EdgeInsets.only(top: 2),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: color)),
                const SizedBox(height: 2),
                Text(description,
                    style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF666666),
                        height: 1.5)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
