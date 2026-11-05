import 'package:flutter/material.dart';

/// The 1.x "Midnight Pro" look: deep background, glass panels, mint accent.
const mint = Color(0xFF3DDBB0);
const ink = Color(0xFF0B0F14);
const panel = Color(0xFF141A22);
const line = Color(0x1FFFFFFF);

ThemeData midnightTheme() {
  final base = ThemeData(
    brightness: Brightness.dark,
    colorScheme: ColorScheme.fromSeed(
      seedColor: mint,
      brightness: Brightness.dark,
      primary: mint,
      surface: panel,
    ),
    scaffoldBackgroundColor: ink,
    useMaterial3: true,
    fontFamily: 'Segoe UI',
  );
  return base.copyWith(
    cardTheme: const CardThemeData(
      color: panel,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(16)),
        side: BorderSide(color: line),
      ),
    ),
    dividerColor: line,
  );
}
