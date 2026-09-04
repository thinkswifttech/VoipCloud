import 'package:flutter/material.dart';

class AppTheme {
  const AppTheme._();

  static const Color swiftRed = Color(0xFFD32031);
  static const Color antiqueRed = Color(0xFF8E1828);
  static const Color brandBlack = Color(0xFF000000);
  static const Color neutralGray = Color(0xFFBCBEC0);
  static const Color cyberPurple = Color(0xFF24073F);
  static const Color accentBlue = Color(0xFF3970C2);
  static const Color accentMagenta = Color(0xFF632776);

  static const String headingFontFamily = 'Raleway';
  static const String bodyFontFamily = 'OpenSans';
  static const String numberFontFamily = bodyFontFamily;

  static TextStyle numberStyle(
    TextStyle? base, {
    FontWeight fontWeight = FontWeight.w600,
    double? letterSpacing = 0.2,
    Color? color,
  }) {
    return (base ?? const TextStyle()).copyWith(
      fontFamily: numberFontFamily,
      fontWeight: fontWeight,
      letterSpacing: letterSpacing,
      color: color,
    );
  }

  static const Color ink = Color(0xFF191B1F);
  static const Color mutedInk = Color(0xFF60646B);
  static const Color canvas = Color(0xFFF8F8F9);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color border = Color(0xFFE2E3E5);
  static const Color darkCanvas = Color(0xFF080A0F);
  static const Color darkSurface = Color(0xFF111318);
  static const Color darkBorder = Color(0xFF2A2D35);
  static const Color avatarBackgroundLight = Color(0xFFF3F4F6);
  static const Color avatarBackgroundDark = Color(0xFF2A2D35);

  /// Near-white / elevated dark surface for modal sheets over the canvas.
  static const Color sheetSurfaceLight = Color(0xFFFCFCFD);
  static const Color sheetSurfaceDark = Color(0xFF161920);

  /// Control wells (avatars, tonal buttons) on [sheetSurface].
  static const Color sheetControlLight = Color(0xFFEEEEF0);
  static const Color sheetControlDark = Color(0xFF2A2D35);

  static Color avatarBackground(Brightness brightness) {
    return brightness == Brightness.dark
        ? avatarBackgroundDark
        : avatarBackgroundLight;
  }

  static Color sheetSurface(Brightness brightness) {
    return brightness == Brightness.dark ? sheetSurfaceDark : sheetSurfaceLight;
  }

  static Color sheetControlBackground(Brightness brightness) {
    return brightness == Brightness.dark ? sheetControlDark : sheetControlLight;
  }

  static const Color avatarForeground = swiftRed;

  static ThemeData lightTheme() {
    return _theme(
      brightness: Brightness.light,
      seed: swiftRed,
      scaffoldBackground: canvas,
      surface: surface,
      outline: border,
      onSurface: ink,
      muted: mutedInk,
    );
  }

  static ThemeData darkTheme() {
    return _theme(
      brightness: Brightness.dark,
      seed: swiftRed,
      scaffoldBackground: darkCanvas,
      surface: darkSurface,
      outline: darkBorder,
      onSurface: const Color(0xFFF7F7F8),
      muted: const Color(0xFFB9BDC7),
    );
  }

  static ThemeData _theme({
    required Brightness brightness,
    required Color seed,
    required Color scaffoldBackground,
    required Color surface,
    required Color outline,
    required Color onSurface,
    required Color muted,
  }) {
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
      surface: surface,
      outline: outline,
    );

    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme.copyWith(
        primary: seed,
        onPrimary: Colors.white,
        // Keep container roles neutral gray — never a pink wash from the red seed.
        primaryContainer: brightness == Brightness.dark
            ? avatarBackgroundDark
            : avatarBackgroundLight,
        onPrimaryContainer: swiftRed,
        secondary: antiqueRed,
        onSecondary: Colors.white,
        secondaryContainer: brightness == Brightness.dark
            ? const Color(0xFF1A1C21)
            : const Color(0xFFF3F4F6),
        onSecondaryContainer: brightness == Brightness.dark
            ? const Color(0xFFF7F7F8)
            : antiqueRed,
        tertiary: accentBlue,
        onTertiary: Colors.white,
        tertiaryContainer: brightness == Brightness.dark
            ? const Color(0xFF1A1C21)
            : const Color(0xFFF3F4F6),
        onTertiaryContainer: brightness == Brightness.dark
            ? const Color(0xFFF7F7F8)
            : onSurface,
        inversePrimary: seed,
        surfaceTint: Colors.transparent,
        surface: surface,
        onSurface: onSurface,
        onSurfaceVariant: muted,
        outline: outline,
        outlineVariant: outline.withValues(alpha: 0.65),
        surfaceContainerLowest: brightness == Brightness.dark
            ? const Color(0xFF0C0E12)
            : const Color(0xFFFBFCFD),
        surfaceContainerLow: brightness == Brightness.dark
            ? const Color(0xFF111318)
            : const Color(0xFFF7F8F9),
        surfaceContainer: brightness == Brightness.dark
            ? const Color(0xFF15181E)
            : const Color(0xFFF5F6F7),
        surfaceContainerHigh: brightness == Brightness.dark
            ? const Color(0xFF1A1C21)
            : const Color(0xFFF3F4F6),
        surfaceContainerHighest: brightness == Brightness.dark
            ? const Color(0xFF1F2228)
            : const Color(0xFFF0F1F3),
      ),
      visualDensity: VisualDensity.adaptivePlatformDensity,
      scaffoldBackgroundColor: scaffoldBackground,
      fontFamily: bodyFontFamily,
    );

    final textTheme = base.textTheme.apply(
      fontFamily: bodyFontFamily,
      bodyColor: onSurface,
      displayColor: onSurface,
    );

    return base.copyWith(
      textTheme: textTheme.copyWith(
        displayLarge: _heading(textTheme.displayLarge),
        displayMedium: _heading(textTheme.displayMedium),
        displaySmall: _heading(textTheme.displaySmall),
        headlineLarge: _heading(textTheme.headlineLarge),
        headlineMedium: textTheme.headlineMedium?.copyWith(
          fontFamily: headingFontFamily,
          fontWeight: FontWeight.w700,
          letterSpacing: 0,
        ),
        headlineSmall: _heading(textTheme.headlineSmall),
        titleLarge: textTheme.titleLarge?.copyWith(
          fontFamily: headingFontFamily,
          fontWeight: FontWeight.w700,
          letterSpacing: 0,
        ),
        titleMedium: textTheme.titleMedium?.copyWith(
          fontFamily: headingFontFamily,
          fontWeight: FontWeight.w600,
          letterSpacing: 0,
        ),
        titleSmall: _heading(textTheme.titleSmall, FontWeight.w600),
        labelLarge: _heading(textTheme.labelLarge, FontWeight.w700),
        labelMedium: _heading(textTheme.labelMedium, FontWeight.w600),
        labelSmall: _heading(textTheme.labelSmall, FontWeight.w600),
        bodyLarge: textTheme.bodyLarge?.copyWith(
          fontFamily: bodyFontFamily,
          letterSpacing: 0,
        ),
        bodyMedium: textTheme.bodyMedium?.copyWith(
          fontFamily: bodyFontFamily,
          color: muted,
          letterSpacing: 0,
        ),
        bodySmall: textTheme.bodySmall?.copyWith(
          fontFamily: bodyFontFamily,
          color: muted,
          letterSpacing: 0,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: surface,
        surfaceTintColor: Colors.transparent,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: outline),
        ),
      ),
      dividerTheme: DividerThemeData(color: outline, thickness: 1, space: 1),
      popupMenuTheme: PopupMenuThemeData(
        color: surface,
        surfaceTintColor: Colors.transparent,
        elevation: 6,
        shadowColor: brandBlack.withValues(alpha: 0.12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: outline),
        ),
        textStyle: TextStyle(
          fontFamily: bodyFontFamily,
          color: onSurface,
          letterSpacing: 0,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: brightness == Brightness.dark
            ? const Color(0xFF0E1015)
            : const Color(0xFFFBFCFD),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: outline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: seed, width: 1.4),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 50),
          textStyle: const TextStyle(
            fontFamily: headingFontFamily,
            fontWeight: FontWeight.w600,
            letterSpacing: 0,
          ),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(44, 44),
          side: BorderSide(color: outline),
          textStyle: const TextStyle(
            fontFamily: headingFontFamily,
            fontWeight: FontWeight.w600,
            letterSpacing: 0,
          ),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: surface,
        indicatorColor: Colors.transparent,
        selectedIconTheme: IconThemeData(color: seed),
        selectedLabelTextStyle: TextStyle(
          fontFamily: headingFontFamily,
          color: seed,
          fontWeight: FontWeight.w700,
          letterSpacing: 0,
        ),
        unselectedIconTheme: IconThemeData(color: muted),
        unselectedLabelTextStyle: TextStyle(
          fontFamily: headingFontFamily,
          color: muted,
          letterSpacing: 0,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface,
        elevation: 1,
        indicatorColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        shadowColor: seed.withValues(alpha: 0.12),
        height: 74,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return TextStyle(
            fontFamily: headingFontFamily,
            color: selected ? seed : muted,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            letterSpacing: 0,
          );
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(color: selected ? seed : muted);
        }),
      ),
      appBarTheme: AppBarTheme(
        elevation: 0,
        centerTitle: false,
        backgroundColor: scaffoldBackground,
        foregroundColor: onSurface,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: textTheme.titleMedium?.copyWith(
          fontFamily: headingFontFamily,
          color: onSurface,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  static TextStyle? _heading(
    TextStyle? style, [
    FontWeight fontWeight = FontWeight.w700,
  ]) {
    return style?.copyWith(
      fontFamily: headingFontFamily,
      fontWeight: fontWeight,
      letterSpacing: 0,
    );
  }
}
