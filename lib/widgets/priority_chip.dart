import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

class PriorityChip extends StatelessWidget {
  const PriorityChip(this.level, {super.key});
  final String level;

  @override
  Widget build(BuildContext context) {
    final color = AppColors.priority(level);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        level,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w700,
          fontSize: 12,
        ),
      ),
    );
  }
}
