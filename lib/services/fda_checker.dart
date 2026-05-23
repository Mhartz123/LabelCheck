import 'package:flutter/material.dart';
class FdaChecker {
  // ── BANNED / RECALLED products from FDA Philippines advisories ──
  static const List<String> _bannedKeywords = [
    'slim fit tea', 'magic slim', 'burn slim coffee',
    'lipo herbal', 'wonder slim', 'quick slim',
    'fat burner pro', 'instant slim patch', 'diet coffee plus',
    'slimming chocolate', 'herbal diabetes cure',
    'beauty whitening capsule', 'whitening glutathione injection',
    'herbal kidney cure', 'sibutramine', 'phenolphthalein',
    'undeclared pharmaceutical', 'not for human consumption',
  ];

  // ── Keywords that indicate a COMPLIANT label ──
  static const List<String> _compliantKeywords = [
    'fda reg', 'fr-', 'food supplement',
    'no approved therapeutic claims',
    'manufactured by', 'distributed by',
    'store at', 'keep out of reach',
  ];

  // ── Keywords that indicate NON-COMPLIANT ──
  static const List<String> _nonCompliantKeywords = [
    'no registration', 'unregistered',
    'no expiry', 'no fda',
  ];

  static ScanResult classify(String ocrText) {
    final lower = ocrText.toLowerCase();

    // Check banned first — highest priority
    for (final keyword in _bannedKeywords) {
      if (lower.contains(keyword)) {
        return ScanResult(
          status: ComplianceStatus.banned,
          matchedKeyword: keyword,
          extractedText: ocrText,
        );
      }
    }

    // Check non-compliant signals
    for (final keyword in _nonCompliantKeywords) {
      if (lower.contains(keyword)) {
        return ScanResult(
          status: ComplianceStatus.nonCompliant,
          matchedKeyword: keyword,
          extractedText: ocrText,
        );
      }
    }

    // Count compliant signals
    int compliantScore = 0;
    String matched = '';
    for (final keyword in _compliantKeywords) {
      if (lower.contains(keyword)) {
        compliantScore++;
        if (matched.isEmpty) matched = keyword;
      }
    }

    // Needs at least (2)? 1 compliant signals to be considered compliant
    if (compliantScore >= 1) {
      return ScanResult(
        status: ComplianceStatus.compliant,
        matchedKeyword: matched,
        extractedText: ocrText,
      );
    }

    // Not enough info to determine
    return ScanResult(
      status: ComplianceStatus.nonCompliant,
      matchedKeyword: 'insufficient label information',
      extractedText: ocrText,
    );
  }
}

enum ComplianceStatus { compliant, nonCompliant, banned }

class ScanResult {
  final ComplianceStatus status;
  final String matchedKeyword;
  final String extractedText;

  const ScanResult({
    required this.status,
    required this.matchedKeyword,
    required this.extractedText,
  });

  String get statusLabel {
    switch (status) {
      case ComplianceStatus.compliant:
        return 'COMPLIANT';
      case ComplianceStatus.nonCompliant:
        return 'NON-COMPLIANT';
      case ComplianceStatus.banned:
        return 'WARNING / BANNED';
    }
  }

  Color get statusColor {
    switch (status) {
      case ComplianceStatus.compliant:
        return const Color(0xFF4CAF50);
      case ComplianceStatus.nonCompliant:
        return const Color(0xFFFF9800);
      case ComplianceStatus.banned:
        return const Color(0xFFF44336);
    }
  }
}