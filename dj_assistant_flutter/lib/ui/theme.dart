import 'package:flutter/material.dart';

// DJ Assistant's design system ("Midnight Pro", 2.0). One source of truth for
// colour, surfaces, spacing, radii, type, icon sizes and motion. Screens read
// these through [DjTokens.of], [Space], [Radii], [DjType], [IconSizes] and
// [Motion]; Material widgets get them from the component themes in [djTheme].

/// Spacing on a 4 px grid.
abstract final class Space {
  static const double x1 = 4, x2 = 8, x3 = 12, x4 = 16, x5 = 20, x6 = 24;
  static const double x8 = 32, x10 = 40, x12 = 48;

  /// Page padding: compact windows get less.
  static double page(double width) => width < 1280 ? x5 : x8;
}

/// Corner radii.
abstract final class Radii {
  static const double sm = 6, md = 8, lg = 12, pill = 999;
  static const small = BorderRadius.all(Radius.circular(sm));
  static const medium = BorderRadius.all(Radius.circular(md));
  static const large = BorderRadius.all(Radius.circular(lg));
}

/// Icon sizes.
abstract final class IconSizes {
  static const double sm = 16, md = 18, lg = 22, xl = 28;
}

/// The type scale (Inter). Sizes are for a dense desktop tool; nothing that
/// carries meaning is smaller than [caption].
abstract final class DjType {
  static const family = 'Inter';
  static const double caption = 11,
      small = 12,
      body = 13,
      title = 15,
      heading = 18,
      display = 22;

  /// Tabular figures, for BPM, key, time and counts that line up in columns.
  static const tabular = [FontFeature.tabularFigures()];
  static const numbers = TextStyle(fontFeatures: tabular);
}

/// Durations and curves. [Motion.of] returns zero durations when the DJ
/// chose Motion: Reduced in Settings.
class Motion extends InheritedWidget {
  const Motion({super.key, required this.reduced, required super.child});
  final bool reduced;

  static const fastMs = 120, baseMs = 200, slowMs = 300;
  static const standard = Curves.easeOutCubic;
  static const emphasized = Curves.easeInOutCubicEmphasized;
  static const exit = Curves.easeInCubic;

  static Motion? _of(BuildContext c) =>
      c.dependOnInheritedWidgetOfExactType<Motion>();

  /// True when animations should be skipped (setting, or the OS asks).
  static bool isReduced(BuildContext c) =>
      (_of(c)?.reduced ?? false) || MediaQuery.disableAnimationsOf(c);

  static Duration fast(BuildContext c) => _d(c, fastMs);
  static Duration base(BuildContext c) => _d(c, baseMs);
  static Duration slow(BuildContext c) => _d(c, slowMs);
  static Duration _d(BuildContext c, int ms) =>
      isReduced(c) ? Duration.zero : Duration(milliseconds: ms);

  @override
  bool updateShouldNotify(Motion old) => old.reduced != reduced;
}

/// Colour and surface tokens, light and dark.
@immutable
class DjTokens extends ThemeExtension<DjTokens> {
  const DjTokens({
    required this.accent,
    required this.onAccent,
    required this.bg,
    required this.panel,
    required this.panel2,
    required this.panel3,
    required this.line,
    required this.lineStrong,
    required this.text,
    required this.muted,
    required this.faint,
    required this.warn,
    required this.danger,
    required this.ok,
    required this.glass,
  });

  /// Brand accent and the text drawn on it.
  final Color accent, onAccent;

  /// App background, then three surface levels: cards, controls and inset
  /// areas, raised and hovered things.
  final Color bg, panel, panel2, panel3;

  /// Hairline borders and dividers; stronger lines for focus-free emphasis.
  final Color line, lineStrong;

  /// Text: primary, secondary, tertiary (all at least 4.5:1 on every surface).
  final Color text, muted, faint;
  final Color warn, danger, ok;

  /// Panels are slightly translucent over the background glow (Panels: Glass).
  final bool glass;

  static DjTokens of(BuildContext c) => Theme.of(c).extension<DjTokens>()!;

  /// A tint of [c] for chips, selected rows and badges.
  Color tint(Color c, [double a = 0.14]) => c.withValues(alpha: a);

  static const dark = DjTokens(
    accent: mint,
    onAccent: Color(0xFF04241B),
    bg: ink,
    panel: Color(0xFF121821),
    panel2: Color(0xFF18202B),
    panel3: Color(0xFF1F2935),
    line: Color(0x17FFFFFF),
    lineStrong: Color(0x2EFFFFFF),
    text: Color(0xFFE8EDF2),
    muted: Color(0xFFB3BDC8),
    faint: Color(0xFF8794A3),
    warn: Color(0xFFF5B454),
    danger: Color(0xFFFF7A7A),
    ok: Color(0xFF7ED3A0),
    glass: true,
  );

  static const light = DjTokens(
    accent: Color(0xFF08765B),
    onAccent: Colors.white,
    bg: Color(0xFFECEFF3),
    panel: Colors.white,
    panel2: Color(0xFFF4F6F9),
    panel3: Color(0xFFE6EAF0),
    line: Color(0x1A0F1720),
    lineStrong: Color(0x330F1720),
    text: Color(0xFF0F1720),
    muted: Color(0xFF3B4654),
    faint: Color(0xFF596677),
    warn: Color(0xFF8A5300),
    danger: Color(0xFFB42318),
    ok: Color(0xFF1B6E30),
    glass: false,
  );

  @override
  DjTokens copyWith({Color? accent, Color? onAccent, bool? glass}) => DjTokens(
    accent: accent ?? this.accent,
    onAccent: onAccent ?? this.onAccent,
    bg: bg,
    panel: panel,
    panel2: panel2,
    panel3: panel3,
    line: line,
    lineStrong: lineStrong,
    text: text,
    muted: muted,
    faint: faint,
    warn: warn,
    danger: danger,
    ok: ok,
    glass: glass ?? this.glass,
  );

  @override
  DjTokens lerp(DjTokens? other, double t) {
    if (other == null) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return DjTokens(
      accent: l(accent, other.accent),
      onAccent: l(onAccent, other.onAccent),
      bg: l(bg, other.bg),
      panel: l(panel, other.panel),
      panel2: l(panel2, other.panel2),
      panel3: l(panel3, other.panel3),
      line: l(line, other.line),
      lineStrong: l(lineStrong, other.lineStrong),
      text: l(text, other.text),
      muted: l(muted, other.muted),
      faint: l(faint, other.faint),
      warn: l(warn, other.warn),
      danger: l(danger, other.danger),
      ok: l(ok, other.ok),
      glass: t < 0.5 ? glass : other.glass,
    );
  }
}

const mint = Color(0xFF3DDBB0);
const ink = Color(0xFF0B0F14);
const panel = Color(0xFF121821);
const line = Color(0x17FFFFFF);

/// Accent presets (Settings → Appearance): dark-theme colour, light-theme
/// colour (darker, for 4.5:1 on white).
const accentPresets = <String, (Color, Color)>{
  'mint': (mint, Color(0xFF08765B)),
  'cyan': (Color(0xFF4CC9F0), Color(0xFF0A6C8C)),
  'violet': (Color(0xFFA78BFA), Color(0xFF6D4BD8)),
  'amber': (Color(0xFFFBBF24), Color(0xFF8A5A00)),
  'rose': (Color(0xFFFB7185), Color(0xFFB4234A)),
};

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

TextTheme _textTheme(DjTokens t) {
  TextStyle s(double size, FontWeight w, Color c, [double h = 1.4]) =>
      TextStyle(
        fontFamily: DjType.family,
        fontSize: size,
        fontWeight: w,
        height: h,
        color: c,
        letterSpacing: size >= DjType.heading ? -0.2 : 0,
      );
  return TextTheme(
    displaySmall: s(28, FontWeight.w700, t.text, 1.2),
    headlineMedium: s(24, FontWeight.w700, t.text, 1.25),
    headlineSmall: s(DjType.display, FontWeight.w700, t.text, 1.25),
    titleLarge: s(DjType.heading, FontWeight.w600, t.text, 1.3),
    titleMedium: s(DjType.title, FontWeight.w600, t.text, 1.35),
    titleSmall: s(DjType.body, FontWeight.w600, t.text),
    bodyLarge: s(14, FontWeight.w400, t.text, 1.45),
    bodyMedium: s(DjType.body, FontWeight.w400, t.text, 1.45),
    bodySmall: s(DjType.small, FontWeight.w400, t.muted),
    labelLarge: s(DjType.body, FontWeight.w600, t.text, 1.2),
    labelMedium: s(DjType.small, FontWeight.w500, t.muted, 1.2),
    labelSmall: s(DjType.caption, FontWeight.w600, t.faint, 1.2),
  );
}

/// The app theme. [accent] is a preset name ([accentPresets]); [glass]
/// follows Settings → Panels.
ThemeData djTheme({
  bool light = false,
  String accent = 'mint',
  bool glass = true,
}) {
  final preset = accentPresets[accent] ?? accentPresets['mint']!;
  final base0 = light ? DjTokens.light : DjTokens.dark;
  final a = light ? preset.$2 : preset.$1;
  final t = base0.copyWith(
    accent: a,
    onAccent: light
        ? Colors.white
        : (a.computeLuminance() > 0.4 ? const Color(0xFF0B1210) : Colors.white),
    glass: glass && !light,
  );
  final scheme =
      ColorScheme.fromSeed(
        seedColor: t.accent,
        brightness: light ? Brightness.light : Brightness.dark,
      ).copyWith(
        primary: t.accent,
        onPrimary: t.onAccent,
        secondary: t.accent,
        onSecondary: t.onAccent,
        surface: t.panel,
        onSurface: t.text,
        onSurfaceVariant: t.muted,
        surfaceContainerLowest: t.bg,
        surfaceContainerLow: t.panel,
        surfaceContainer: t.panel2,
        surfaceContainerHigh: t.panel3,
        surfaceContainerHighest: t.panel3,
        outline: t.lineStrong,
        outlineVariant: t.line,
        error: t.danger,
      );
  final text = _textTheme(t);
  final focus = BorderSide(color: t.accent, width: 1.5);
  const tight = VisualDensity(horizontal: -1, vertical: -1);
  WidgetStateProperty<Color?> overlay(Color c) =>
      WidgetStateProperty.resolveWith((s) {
        if (s.contains(WidgetState.pressed)) return c.withValues(alpha: 0.16);
        if (s.contains(WidgetState.focused)) return c.withValues(alpha: 0.14);
        if (s.contains(WidgetState.hovered)) return c.withValues(alpha: 0.08);
        return null;
      });
  final buttonShape = WidgetStatePropertyAll<OutlinedBorder>(
    RoundedRectangleBorder(borderRadius: Radii.medium),
  );
  const buttonPad = WidgetStatePropertyAll(
    EdgeInsets.symmetric(horizontal: Space.x4, vertical: Space.x2 + 2),
  );
  final buttonText = WidgetStatePropertyAll(text.labelLarge);
  const minSize = WidgetStatePropertyAll(Size(64, 36));
  final inputBorder = OutlineInputBorder(
    borderRadius: Radii.medium,
    borderSide: BorderSide(color: t.line),
  );

  return ThemeData(
    brightness: light ? Brightness.light : Brightness.dark,
    colorScheme: scheme,
    useMaterial3: true,
    fontFamily: DjType.family,
    textTheme: text,
    primaryTextTheme: text,
    scaffoldBackgroundColor: t.bg,
    canvasColor: t.panel,
    visualDensity: tight,
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    splashFactory: InkSparkle.splashFactory,
    focusColor: t.accent.withValues(alpha: 0.14),
    hoverColor: t.text.withValues(alpha: 0.05),
    highlightColor: Colors.transparent,
    dividerColor: t.line,
    iconTheme: IconThemeData(color: t.muted, size: IconSizes.md),
    extensions: [t],
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.macOS: FadeForwardsPageTransitionsBuilder(),
      },
    ),
    cardTheme: CardThemeData(
      color: t.glass ? t.panel.withValues(alpha: 0.86) : t.panel,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: Radii.large,
        side: BorderSide(color: t.line),
      ),
    ),
    dividerTheme: DividerThemeData(color: t.line, space: 1, thickness: 1),
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        shape: buttonShape,
        padding: buttonPad,
        textStyle: buttonText,
        minimumSize: minSize,
        backgroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.disabled) ? t.panel3 : t.accent,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.disabled) ? t.faint : t.onAccent,
        ),
        overlayColor: overlay(t.onAccent),
        elevation: const WidgetStatePropertyAll(0),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ButtonStyle(
        shape: buttonShape,
        padding: buttonPad,
        textStyle: buttonText,
        minimumSize: minSize,
        elevation: const WidgetStatePropertyAll(0),
        backgroundColor: WidgetStatePropertyAll(t.panel3),
        foregroundColor: WidgetStatePropertyAll(t.text),
        overlayColor: overlay(t.text),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(
        shape: buttonShape,
        padding: buttonPad,
        textStyle: buttonText,
        minimumSize: minSize,
        foregroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.disabled) ? t.faint : t.text,
        ),
        side: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.focused)
              ? focus
              : BorderSide(color: t.lineStrong),
        ),
        overlayColor: overlay(t.text),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(
        shape: buttonShape,
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: Space.x3, vertical: Space.x2),
        ),
        textStyle: buttonText,
        foregroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.disabled) ? t.faint : t.accent,
        ),
        overlayColor: overlay(t.accent),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        shape: buttonShape,
        iconSize: const WidgetStatePropertyAll(IconSizes.md),
        foregroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.disabled)
              ? t.faint.withValues(alpha: 0.5)
              : s.contains(WidgetState.selected)
              ? t.accent
              : t.muted,
        ),
        overlayColor: overlay(t.text),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        shape: buttonShape,
        textStyle: WidgetStatePropertyAll(text.labelMedium),
        visualDensity: tight,
        side: WidgetStatePropertyAll(BorderSide(color: t.lineStrong)),
        backgroundColor: WidgetStateProperty.resolveWith(
          (s) =>
              s.contains(WidgetState.selected) ? t.tint(t.accent, 0.18) : null,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? t.accent : t.muted,
        ),
        overlayColor: overlay(t.text),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: t.panel2,
      selectedColor: t.tint(t.accent, 0.18),
      disabledColor: t.panel2,
      side: BorderSide(color: t.line),
      shape: RoundedRectangleBorder(borderRadius: Radii.medium),
      labelStyle: text.labelMedium?.copyWith(color: t.text),
      secondaryLabelStyle: text.labelMedium?.copyWith(color: t.accent),
      padding: const EdgeInsets.symmetric(horizontal: Space.x1),
      checkmarkColor: t.accent,
      iconTheme: IconThemeData(color: t.muted, size: IconSizes.sm),
      showCheckmark: false,
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: t.panel2,
      hoverColor: t.panel3,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: Space.x3,
        vertical: Space.x3,
      ),
      border: inputBorder,
      enabledBorder: inputBorder,
      focusedBorder: inputBorder.copyWith(borderSide: focus),
      errorBorder: inputBorder.copyWith(
        borderSide: BorderSide(color: t.danger),
      ),
      labelStyle: text.bodySmall,
      floatingLabelStyle: text.labelMedium?.copyWith(color: t.accent),
      hintStyle: text.bodyMedium?.copyWith(color: t.faint),
      helperStyle: text.bodySmall?.copyWith(color: t.faint),
      prefixIconColor: t.faint,
      suffixIconColor: t.faint,
    ),
    dropdownMenuTheme: DropdownMenuThemeData(
      textStyle: text.bodyMedium,
      menuStyle: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(t.panel2),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: Radii.medium,
            side: BorderSide(color: t.line),
          ),
        ),
      ),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(t.panel2),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: Radii.medium,
            side: BorderSide(color: t.line),
          ),
        ),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: t.panel2,
      textStyle: text.bodyMedium,
      shape: RoundedRectangleBorder(
        borderRadius: Radii.medium,
        side: BorderSide(color: t.line),
      ),
    ),
    listTileTheme: ListTileThemeData(
      dense: true,
      shape: RoundedRectangleBorder(borderRadius: Radii.medium),
      iconColor: t.muted,
      textColor: t.text,
      selectedColor: t.accent,
      selectedTileColor: t.tint(t.accent, 0.12),
      titleTextStyle: text.bodyMedium,
      subtitleTextStyle: text.bodySmall,
      contentPadding: const EdgeInsets.symmetric(horizontal: Space.x3),
      minVerticalPadding: Space.x1,
    ),
    sliderTheme: SliderThemeData(
      trackHeight: 3,
      activeTrackColor: t.accent,
      inactiveTrackColor: t.lineStrong,
      thumbColor: t.accent,
      overlayColor: t.tint(t.accent, 0.16),
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
      valueIndicatorColor: t.panel3,
      valueIndicatorTextStyle: text.labelMedium?.copyWith(color: t.text),
      showValueIndicator: ShowValueIndicator.onDrag,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? t.onAccent : t.faint,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? t.accent : t.panel3,
      ),
      trackOutlineColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? t.accent : t.lineStrong,
      ),
    ),
    checkboxTheme: CheckboxThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      side: BorderSide(color: t.faint, width: 1.5),
      fillColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? t.accent : null,
      ),
      checkColor: WidgetStatePropertyAll(t.onAccent),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? t.accent : t.faint,
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: t.accent,
      linearTrackColor: t.panel3,
      circularTrackColor: Colors.transparent,
      linearMinHeight: 4,
      borderRadius: Radii.small,
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: t.text,
      unselectedLabelColor: t.faint,
      labelStyle: text.labelLarge,
      unselectedLabelStyle: text.labelLarge,
      indicatorColor: t.accent,
      dividerColor: t.line,
      indicatorSize: TabBarIndicatorSize.label,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: t.panel,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: Radii.large,
        side: BorderSide(color: t.line),
      ),
      titleTextStyle: text.titleLarge,
      contentTextStyle: text.bodyMedium?.copyWith(color: t.muted),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: t.panel,
      surfaceTintColor: Colors.transparent,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: t.panel3,
      contentTextStyle: text.bodyMedium,
      actionTextColor: t.accent,
      shape: RoundedRectangleBorder(
        borderRadius: Radii.medium,
        side: BorderSide(color: t.lineStrong),
      ),
      width: 520,
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 500),
      decoration: BoxDecoration(
        color: light ? const Color(0xFF1B232D) : const Color(0xFFE8EDF2),
        borderRadius: Radii.small,
      ),
      textStyle: text.labelMedium?.copyWith(
        color: light ? Colors.white : const Color(0xFF0B0F14),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: Space.x2,
        vertical: Space.x1 + 2,
      ),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: const WidgetStatePropertyAll(6),
      radius: const Radius.circular(3),
      thumbColor: WidgetStateProperty.resolveWith(
        (s) =>
            s.contains(WidgetState.hovered) || s.contains(WidgetState.dragged)
            ? t.faint
            : t.lineStrong,
      ),
    ),
    dataTableTheme: DataTableThemeData(
      headingTextStyle: text.labelSmall,
      dataTextStyle: text.bodyMedium,
      dividerThickness: 1,
      headingRowHeight: 36,
      dataRowMinHeight: 34,
      dataRowMaxHeight: 40,
    ),
    badgeTheme: BadgeThemeData(
      backgroundColor: t.accent,
      textColor: t.onAccent,
      textStyle: text.labelSmall,
    ),
  );
}

/// The 1.x name, kept for callers.
ThemeData midnightTheme() => djTheme();
