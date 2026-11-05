import 'package:flutter/material.dart';

/// Design tokens of the 1.x "Midnight Pro" look (deep background, glass panels,
/// mint accent), as a ThemeExtension so every screen reads the same values.
@immutable
class DjTokens extends ThemeExtension<DjTokens> {
  const DjTokens({
    required this.accent,
    required this.panel,
    required this.panel2,
    required this.line,
    required this.faint,
    required this.muted,
    required this.warn,
    required this.danger,
    required this.ok,
  });
  final Color accent, panel, panel2, line, faint, muted, warn, danger, ok;

  static DjTokens of(BuildContext c) => Theme.of(c).extension<DjTokens>()!;

  @override
  DjTokens copyWith({Color? accent}) => DjTokens(
    accent: accent ?? this.accent,
    panel: panel,
    panel2: panel2,
    line: line,
    faint: faint,
    muted: muted,
    warn: warn,
    danger: danger,
    ok: ok,
  );

  @override
  DjTokens lerp(DjTokens? other, double t) {
    if (other == null) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return DjTokens(
      accent: l(accent, other.accent),
      panel: l(panel, other.panel),
      panel2: l(panel2, other.panel2),
      line: l(line, other.line),
      faint: l(faint, other.faint),
      muted: l(muted, other.muted),
      warn: l(warn, other.warn),
      danger: l(danger, other.danger),
      ok: l(ok, other.ok),
    );
  }
}

const mint = Color(0xFF3DDBB0);
const ink = Color(0xFF0B0F14);
const panel = Color(0xFF141A22);
const line = Color(0x1FFFFFFF);

/// Crate and track colours (1.x palette).
const crateColors = <String, Color>{
  'red': Color(0xFFEF5350),
  'orange': Color(0xFFFF9800),
  'yellow': Color(0xFFFFD54F),
  'green': Color(0xFF66BB6A),
  'teal': Color(0xFF26A69A),
  'blue': Color(0xFF42A5F5),
  'purple': Color(0xFFAB47BC),
  'pink': Color(0xFFEC407A),
  'grey': Color(0xFF9E9E9E),
};

ThemeData djTheme({bool light = false, Color accent = mint}) {
  final tokens = light
      ? DjTokens(
          accent: const Color(0xFF0E9F7A),
          panel: Colors.white,
          panel2: const Color(0xFFF1F4F7),
          line: const Color(0x1F000000),
          faint: const Color(0x8A000000),
          muted: const Color(0xB3000000),
          warn: const Color(0xFFB26A00),
          danger: const Color(0xFFC62828),
          ok: const Color(0xFF2E7D32),
        )
      : DjTokens(
          accent: accent,
          panel: panel,
          panel2: const Color(0xFF1B232D),
          line: line,
          faint: Colors.white54,
          muted: Colors.white70,
          warn: const Color(0xFFFFB74D),
          danger: const Color(0xFFFF6B6B),
          ok: const Color(0xFF81C784),
        );
  final scheme = ColorScheme.fromSeed(
    seedColor: tokens.accent,
    brightness: light ? Brightness.light : Brightness.dark,
    primary: tokens.accent,
    surface: tokens.panel,
  );
  final base = ThemeData(
    brightness: light ? Brightness.light : Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: light ? const Color(0xFFE9EDF1) : ink,
    useMaterial3: true,
    fontFamily: 'Segoe UI',
    visualDensity: VisualDensity.compact,
  );
  return base.copyWith(
    extensions: [tokens],
    cardTheme: CardThemeData(
      color: tokens.panel,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.all(Radius.circular(14)),
        side: BorderSide(color: tokens.line),
      ),
    ),
    dividerColor: tokens.line,
    dividerTheme: DividerThemeData(color: tokens.line, space: 1),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: tokens.panel2,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: tokens.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: tokens.line),
      ),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    tooltipTheme: const TooltipThemeData(
      waitDuration: Duration(milliseconds: 500),
    ),
  );
}

/// The 1.x name, kept for callers.
ThemeData midnightTheme() => djTheme();
