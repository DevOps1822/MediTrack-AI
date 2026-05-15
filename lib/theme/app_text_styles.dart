import 'package:flutter/material.dart';

import 'app_colors.dart';

class AppTextStyles {
  static const headline = TextStyle(
    fontSize: 24,
    fontWeight: FontWeight.w700,
    color: AppColors.text,
  );
  static const title = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.w700,
    color: AppColors.text,
  );
  static const body = TextStyle(fontSize: 14, color: AppColors.text);
  static const muted = TextStyle(fontSize: 14, color: AppColors.muted);
}
