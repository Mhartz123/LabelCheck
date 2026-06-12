import 'package:flutter/material.dart';

class NewsScreen extends StatelessWidget {
  final VoidCallback onScanTap;
  final VoidCallback onRecordsTap;

  const NewsScreen({
    super.key,
    required this.onScanTap,
    required this.onRecordsTap,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade200,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            children: [
              // ── Newsletter placeholder ─────────────────────────────────────
              Expanded(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.grey.shade400, width: 1.5),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Newsletter Placeholder',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF555555),
                        ),
                      ),
                      const Spacer(),
                      // Date stamp bottom right
                      Align(
                        alignment: Alignment.bottomRight,
                        child: Text(
                          'XX / XX / XX',
                          style: TextStyle(
                            fontSize: 13,
                            color: Colors.grey.shade500,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),

              // ── Shortcut buttons ──────────────────────────────────────────
              Row(
                children: [
                  // Camera shortcut
                  Expanded(
                    child: GestureDetector(
                      onTap: onScanTap,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            vertical: 20, horizontal: 16),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade300,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 42,
                              height: 42,
                              decoration: BoxDecoration(
                                color: Colors.grey.shade400,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: const Icon(Icons.camera_alt_outlined,
                                  color: Colors.white, size: 22),
                            ),
                            const SizedBox(width: 12),
                            const Text(
                              'Camera',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF333333),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),

                  // Records shortcut
                  Expanded(
                    child: GestureDetector(
                      onTap: onRecordsTap,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            vertical: 20, horizontal: 16),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade300,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 42,
                              height: 42,
                              decoration: BoxDecoration(
                                color: Colors.grey.shade400,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: const Icon(Icons.list_alt_outlined,
                                  color: Colors.white, size: 22),
                            ),
                            const SizedBox(width: 12),
                            const Text(
                              'Records',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF333333),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}