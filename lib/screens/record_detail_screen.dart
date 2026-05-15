import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

class RecordDetailScreen extends StatelessWidget {
  final File file;

  const RecordDetailScreen({super.key, required this.file});

  String _formatDate(DateTime dt) =>
      '${dt.year}-${_pad(dt.month)}-${_pad(dt.day)}  '
      '${_pad(dt.hour)}:${_pad(dt.minute)}';

  String _pad(int n) => n.toString().padLeft(2, '0');

  @override
  Widget build(BuildContext context) {
    final name = p.basenameWithoutExtension(file.path);
    final date = file.lastModifiedSync();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Compliance Check',
            style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        elevation: 1,
        centerTitle: true,
      ),
      backgroundColor: Colors.white,
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Photo
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.file(
                file,
                width: double.infinity,
                height: 260,
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(height: 16),

            // Info card
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.grey.shade300),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // FDA Status row (placeholder)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: const [
                          Text('FDA Status : —',
                              style: TextStyle(fontSize: 13)),
                          SizedBox(height: 4),
                          Text('Product Type : —',
                              style: TextStyle(fontSize: 13)),
                          SizedBox(height: 4),
                          Text('Confidence : —',
                              style: TextStyle(fontSize: 13)),
                        ],
                      ),
                      // Status color dot (placeholder = grey)
                      Container(
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          color: Colors.grey.shade400,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ],
                  ),
                  const Divider(height: 20),

                  // Name
                  Text('Name : $name',
                      style: const TextStyle(fontSize: 13)),
                  const SizedBox(height: 4),

                  // Date
                  Text('Date : ${_formatDate(date)}',
                      style: const TextStyle(fontSize: 13)),
                  const Divider(height: 20),

                  // Note (placeholder)
                  const Text(
                    'Note : Compliance data not yet available.',
                    style: TextStyle(
                        fontSize: 12, color: Colors.black54),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // FDA Hotline (placeholder)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                  horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.grey.shade300),
              ),
              child: const Text(
                'FDA Hotline : —',
                style:
                    TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
