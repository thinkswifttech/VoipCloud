import 'package:flutter/material.dart';

/// VoipCloud app logo used on splash / branded intros / About.
class AppBrandIcon extends StatelessWidget {
  const AppBrandIcon({
    super.key,
    this.size = 88,
    this.semanticLabel = 'VoipCloud',
    this.showGlow = false,
    this.circular = false,
    this.borderRadius,
  });

  static const circleAssetPath = 'assets/brand/app_icon_circle.png';
  static const assetPath = 'assets/brand/app_icon.png';

  final double size;
  final String semanticLabel;
  final bool showGlow;

  /// When true, uses the circular asset. When false (default for About /
  /// splash), uses the original square icon clipped with [borderRadius].
  final bool circular;

  /// Corner radius for non-circular icons. Defaults to ~22% of [size].
  final double? borderRadius;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final icon = Image.asset(
      circular ? circleAssetPath : assetPath,
      width: size,
      height: size,
      fit: BoxFit.cover,
      semanticLabel: semanticLabel,
      filterQuality: FilterQuality.high,
    );

    final Widget shaped = circular
        ? icon
        : ClipRRect(
            borderRadius: BorderRadius.circular(borderRadius ?? size * 0.22),
            child: icon,
          );

    if (!showGlow) {
      return shaped;
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        shape: circular ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: circular
            ? null
            : BorderRadius.circular(borderRadius ?? size * 0.22),
        boxShadow: [
          BoxShadow(
            color: const Color(
              0xFFD32031,
            ).withValues(alpha: isDark ? 0.34 : 0.22),
            blurRadius: size * 0.55,
            spreadRadius: size * 0.02,
          ),
          BoxShadow(
            color: const Color(
              0xFFD32031,
            ).withValues(alpha: isDark ? 0.16 : 0.10),
            blurRadius: size * 0.95,
            spreadRadius: size * 0.08,
          ),
        ],
      ),
      child: shaped,
    );
  }
}
