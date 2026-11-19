/// Material 3 with the phone app's teal seed; light and dark follow the
/// system. Flat cards with a thin outline read better on a wide screen
/// than shadows. Author: Hao Tran.
library;

import 'package:flutter/material.dart';

ThemeData appTheme(Brightness brightness) {
  final colors = ColorScheme.fromSeed(
    seedColor: Colors.teal,
    brightness: brightness,
  );
  return ThemeData(
    colorScheme: colors,
    visualDensity: VisualDensity.standard,
    scaffoldBackgroundColor: colors.surface,
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: colors.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: colors.outlineVariant),
      ),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: colors.surfaceContainer,
      indicatorColor: colors.secondaryContainer,
    ),
    dividerTheme: DividerThemeData(color: colors.outlineVariant, space: 1),
    listTileTheme: const ListTileThemeData(
      contentPadding: EdgeInsets.symmetric(horizontal: 16),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}

/// Green for "fine": Material has no success role.
Color okColor(ColorScheme colors) => colors.brightness == Brightness.dark
    ? Colors.green.shade300
    : Colors.green.shade700;
