import 'package:flutter/material.dart';

class AppColors {
  static const primary = Color(0xFF0B6B67);
  static const primaryDark = Color(0xFF064E4A);
  static const accent = Color(0xFF16A3B8);
  static const background = Color(0xFFF7F9FC);
  static const surface = Color(0xFFFFFFFF);
  static const text = Color(0xFF111827);
  static const muted = Color(0xFF64748B);
  static const border = Color(0xFFE5E7EB);
  static const success = Color(0xFF10B981);
  static const medium = Color(0xFFF59E0B);
  static const high = Color(0xFFF97316);
  static const urgent = Color(0xFFDC2626);
  static const error = Color(0xFFE11D48);

  static Color priority(String value) {
    switch (value.toLowerCase()) {
      case 'urgent':
        return urgent;
      case 'high':
        return high;
      case 'medium':
        return medium;
      default:
        return success;
    }
  }
}
