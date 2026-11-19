import 'package:flutter/material.dart';

/// The colours that identify an account ("line"), derived from one base colour
/// so every use stays consistent and readable in light and dark mode.
///
/// Design rules (see Project Documents/Softphone_App_Multi_Account_Plan.md):
/// - one accent per line, never red, green or amber: those mean error, success
///   and warning everywhere else in the app;
/// - the accent is used as a soft tint behind small text (tags, selected
///   segment) and as a thin mark, never as a large filled area;
/// - a line is never identified by colour alone: its number or name is always
///   shown with it.
@immutable
class LineTone {
  const LineTone({
    required this.base,
    required this.soft,
    required this.onSoft,
    required this.border,
  });

  /// The line's own colour; for marks and the selected outline.
  final Color base;

  /// A faint tint of [base] for tag and selected-segment backgrounds.
  final Color soft;

  /// Text on [soft]: [base] adjusted until it has at least 4.5:1 contrast.
  final Color onSoft;

  /// Outline of a selected or highlighted element.
  final Color border;

  /// [surface] is what [soft] is drawn on (the card or sheet colour).
  factory LineTone.from(int baseValue, Brightness brightness, Color surface) {
    final base = Color(baseValue);
    final dark = brightness == Brightness.dark;
    final soft = Color.alphaBlend(
      base.withValues(alpha: dark ? 0.22 : 0.10),
      surface,
    );
    return LineTone(
      base: base,
      soft: soft,
      onSoft: readableOn(base, soft),
      border: base.withValues(alpha: dark ? 0.70 : 0.55),
    );
  }

  static LineTone of(BuildContext context, int baseValue) {
    final theme = Theme.of(context);
    return LineTone.from(
      baseValue,
      theme.brightness,
      theme.colorScheme.surface,
    );
  }
}

/// WCAG contrast ratio between two opaque colours (1 to 21).
double contrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final lighter = la > lb ? la : lb;
  final darker = la > lb ? lb : la;
  return (lighter + 0.05) / (darker + 0.05);
}

/// [color], moved toward black or white just enough to read on [background]
/// (at least [minimum]:1). Keeps the hue so the line is still recognisable.
Color readableOn(Color color, Color background, {double minimum = 4.5}) {
  if (contrastRatio(color, background) >= minimum) return color;
  final hsl = HSLColor.fromColor(color);
  final towardLight = background.computeLuminance() < 0.4;
  var lightness = hsl.lightness;
  var candidate = color;
  for (var i = 0; i < 40; i++) {
    lightness = (towardLight ? lightness + 0.02 : lightness - 0.02).clamp(
      0.0,
      1.0,
    );
    candidate = hsl.withLightness(lightness).toColor();
    if (contrastRatio(candidate, background) >= minimum) return candidate;
  }
  return towardLight ? Colors.white : Colors.black;
}
