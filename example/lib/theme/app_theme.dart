import 'dart:ui';
import 'package:flutter/material.dart';

class AppTheme {
  static ThemeData get light => ThemeData(
        colorSchemeSeed: Colors.blue,
        useMaterial3: true,
        scrollbarTheme: ScrollbarThemeData(
          thumbVisibility: WidgetStateProperty.all(true),
          interactive: true,
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: ButtonStyle(
            shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            mouseCursor: const WidgetStatePropertyAll(SystemMouseCursors.click),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: ButtonStyle(
            shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            mouseCursor: const WidgetStatePropertyAll(SystemMouseCursors.click),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: ButtonStyle(
            shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            mouseCursor: const WidgetStatePropertyAll(SystemMouseCursors.click),
          ),
        ),
        iconButtonTheme: const IconButtonThemeData(
          style: ButtonStyle(
            mouseCursor: WidgetStatePropertyAll(SystemMouseCursors.click),
          ),
        ),
        floatingActionButtonTheme: const FloatingActionButtonThemeData(
          mouseCursor: WidgetStatePropertyAll(SystemMouseCursors.click),
        ),
        switchTheme: SwitchThemeData(
          mouseCursor: WidgetStateProperty.resolveWith((states) => SystemMouseCursors.click),
        ),
        checkboxTheme: CheckboxThemeData(
          mouseCursor: WidgetStateProperty.resolveWith((states) => SystemMouseCursors.click),
        ),
        radioTheme: RadioThemeData(
          mouseCursor: WidgetStateProperty.resolveWith((states) => SystemMouseCursors.click),
        ),
        dropdownMenuTheme: const DropdownMenuThemeData(
          menuStyle: MenuStyle(mouseCursor: WidgetStatePropertyAll(SystemMouseCursors.click)),
        ),
        dataTableTheme: DataTableThemeData(
          dataTextStyle: const TextStyle(fontSize: 13),
          headingTextStyle: const TextStyle(fontWeight: FontWeight.bold),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      );

  static ScrollBehavior get scrollBehavior => const MaterialScrollBehavior().copyWith(
        dragDevices: {
          PointerDeviceKind.mouse,
          PointerDeviceKind.touch,
          PointerDeviceKind.stylus,
          PointerDeviceKind.trackpad,
        },
      );
}
