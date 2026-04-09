import 'package:flutter/material.dart';

class AppTextField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final bool obscureText;
  final Widget? suffixIcon;
  final VoidCallback? onClear;

  const AppTextField({
    super.key,
    required this.controller,
    required this.label,
    this.obscureText = false,
    this.suffixIcon,
    this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final hasClear = value.text.isNotEmpty;

        Widget? suffix;
        if (suffixIcon != null || hasClear) {
          suffix = Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ?suffixIcon,
              if (hasClear)
                IconButton(
                  icon: const Icon(Icons.clear, size: 16),
                  onPressed: () {
                    controller.clear();
                    onClear?.call();
                  },
                  visualDensity: VisualDensity.compact,
                ),
            ],
          );
        }

        return TextField(
          controller: controller,
          obscureText: obscureText,
          style: const TextStyle(fontSize: 13),
          decoration: InputDecoration(
            hintText: label,
            hintStyle: TextStyle(fontSize: 13, color: Colors.grey[500]),
            filled: true,
            fillColor: cs.surface,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
            constraints: const BoxConstraints(minHeight: 36, maxHeight: 36),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12),
            suffixIcon: suffix,
            suffixIconConstraints: const BoxConstraints(maxHeight: 36),
          ),
        );
      },
    );
  }
}
