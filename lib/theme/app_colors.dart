import 'package:flutter/material.dart';

/// Centralized color palette for the soft-green clinical theme.
class AppColors {
  AppColors._();

  static const Color bg = Color(0xFFF0F7F2);          // page background
  static const Color surface = Color(0xFFFFFFFF);      // cards / bars
  static const Color surfaceAlt = Color(0xFFE8F5EC);    // secondary surface
  static const Color border = Color(0xFFC8E0CE);

  static const Color accent = Color(0xFF2E7D32);        // primary green
  static const Color accentLight = Color(0xFF4CAF50);

  static const Color text = Color(0xFF1A2E1C);
  static const Color muted = Color(0xFF6A8F6E);

  // Compliance pill colors
  static const Color compliantBg = Color(0xFFE8F5E9);
  static const Color compliantText = Color(0xFF1B5E20);

  static const Color nonCompliantBg = Color(0xFFFFF8E1);
  static const Color nonCompliantText = Color(0xFFE65100);

  static const Color bannedBg = Color(0xFFFFEBEE);
  static const Color bannedText = Color(0xFFB71C1C);

  // Camera screen (stays dark regardless of theme)
  static const Color cameraBg = Color(0xFF111111);
}