import 'package:flutter/material.dart';

import '../../app/theme/app_theme.dart';
import 'app_brand_icon.dart';

class StartupBrandIntro extends StatefulWidget {
  const StartupBrandIntro({super.key});

  @override
  State<StartupBrandIntro> createState() => _StartupBrandIntroState();
}

class _StartupBrandIntroState extends State<StartupBrandIntro>
    with SingleTickerProviderStateMixin {
  late final AnimationController _introController;
  late final Animation<double> _glow;
  late final Animation<double> _iconFade;
  late final Animation<double> _iconScale;
  late final Animation<double> _copyFade;
  late final Animation<Offset> _copySlide;
  late final Animation<double> _progressFade;

  @override
  void initState() {
    super.initState();
    _introController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );

    _glow = CurvedAnimation(
      parent: _introController,
      curve: const Interval(0, 0.55, curve: Curves.easeOutCubic),
    );
    _iconFade = CurvedAnimation(
      parent: _introController,
      curve: const Interval(0.05, 0.42, curve: Curves.easeOut),
    );
    _iconScale = Tween<double>(begin: 0.86, end: 1).animate(
      CurvedAnimation(
        parent: _introController,
        curve: const Interval(0.05, 0.58, curve: Curves.easeOutCubic),
      ),
    );
    _copyFade = CurvedAnimation(
      parent: _introController,
      curve: const Interval(0.34, 0.78, curve: Curves.easeOutCubic),
    );
    _copySlide = Tween<Offset>(begin: const Offset(0, 0.12), end: Offset.zero)
        .animate(
          CurvedAnimation(
            parent: _introController,
            curve: const Interval(0.34, 0.82, curve: Curves.easeOutCubic),
          ),
        );
    _progressFade = CurvedAnimation(
      parent: _introController,
      curve: const Interval(0.55, 1, curve: Curves.easeOut),
    );

    _introController.forward();
  }

  @override
  void dispose() {
    _introController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final reduceMotion = MediaQuery.of(context).disableAnimations;

    return Stack(
      fit: StackFit.expand,
      children: [
        _StartupBackdrop(isDark: isDark),
        SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 36),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: AnimatedBuilder(
                  animation: _introController,
                  builder: (context, _) {
                    final glowStrength = reduceMotion ? 1.0 : _glow.value;
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 168,
                          height: 168,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              Opacity(
                                opacity: (isDark ? 0.55 : 0.42) * glowStrength,
                                child: Container(
                                  width: 148,
                                  height: 148,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    gradient: RadialGradient(
                                      colors: [
                                        theme.colorScheme.primary.withValues(
                                          alpha: isDark ? 0.38 : 0.28,
                                        ),
                                        theme.colorScheme.primary.withValues(
                                          alpha: isDark ? 0.12 : 0.08,
                                        ),
                                        Colors.transparent,
                                      ],
                                      stops: const [0, 0.48, 1],
                                    ),
                                  ),
                                ),
                              ),
                              FadeTransition(
                                opacity: reduceMotion
                                    ? const AlwaysStoppedAnimation(1)
                                    : _iconFade,
                                child: ScaleTransition(
                                  scale: reduceMotion
                                      ? const AlwaysStoppedAnimation(1)
                                      : _iconScale,
                                  child: const AppBrandIcon(
                                    size: 96,
                                    circular: false,
                                    showGlow: true,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 28),
                        FadeTransition(
                          opacity: reduceMotion
                              ? const AlwaysStoppedAnimation(1)
                              : _copyFade,
                          child: SlideTransition(
                            position: reduceMotion
                                ? const AlwaysStoppedAnimation(Offset.zero)
                                : _copySlide,
                            child: Column(
                              children: [
                                Text(
                                  'VoipCloud',
                                  textAlign: TextAlign.center,
                                  style: theme.textTheme.headlineSmall
                                      ?.copyWith(
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: -0.3,
                                      ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'Connecting…',
                                  textAlign: TextAlign.center,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                    letterSpacing: 0.2,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 36),
                        FadeTransition(
                          opacity: reduceMotion
                              ? const AlwaysStoppedAnimation(1)
                              : _progressFade,
                          child: SizedBox(
                            width: 120,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(999),
                              child: LinearProgressIndicator(
                                minHeight: 2.5,
                                backgroundColor: theme.colorScheme.outline
                                    .withValues(alpha: isDark ? 0.28 : 0.4),
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _StartupBackdrop extends StatelessWidget {
  const _StartupBackdrop({required this.isDark});

  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: isDark
              ? const [
                  Color(0xFF0B0D12),
                  AppTheme.darkCanvas,
                  Color(0xFF0E1016),
                ]
              : const [Color(0xFFFCFCFD), AppTheme.canvas, Color(0xFFF7F4F5)],
        ),
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(0, -0.18),
            radius: 0.85,
            colors: [
              AppTheme.swiftRed.withValues(alpha: isDark ? 0.10 : 0.055),
              Colors.transparent,
            ],
          ),
        ),
      ),
    );
  }
}
