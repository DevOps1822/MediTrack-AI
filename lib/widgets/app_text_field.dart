import 'package:flutter/material.dart';

class AppTextField extends StatelessWidget {
  const AppTextField({
    super.key,
    required this.controller,
    required this.label,
    this.validator,
    this.keyboardType,
    this.textCapitalization = TextCapitalization.none,
    this.maxLines = 1,
    this.obscureText = false,
    this.suffixIcon,
    this.readOnly = false,
    this.enabled = true,
    this.helperText,
    this.onTap,
  });
  final TextEditingController controller;
  final String label;
  final String? Function(String?)? validator;
  final TextInputType? keyboardType;
  final TextCapitalization textCapitalization;
  final int maxLines;
  final bool obscureText;
  final Widget? suffixIcon;
  final bool readOnly;
  final bool enabled;
  final String? helperText;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => TextFormField(
    controller: controller,
    decoration: InputDecoration(
      labelText: label,
      suffixIcon: suffixIcon,
      helperText: helperText,
    ),
    validator: validator,
    keyboardType: keyboardType,
    textCapitalization: textCapitalization,
    maxLines: obscureText ? 1 : maxLines,
    obscureText: obscureText,
    readOnly: readOnly,
    enabled: enabled,
    onTap: onTap,
  );
}
