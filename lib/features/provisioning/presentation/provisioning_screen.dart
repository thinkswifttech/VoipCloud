import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/route_names.dart';
import '../../../app/theme/app_theme.dart';
import '../../../shared/icons/app_icons.dart';
import '../../../shared/platform/desktop_platform.dart';
import '../../../shared/widgets/app_brand_icon.dart';
import '../../../shared/widgets/responsive.dart';
import 'provisioning_controller.dart';

class ProvisioningScreen extends ConsumerStatefulWidget {
  const ProvisioningScreen({super.key});

  @override
  ConsumerState<ProvisioningScreen> createState() => _ProvisioningScreenState();
}

class _ProvisioningScreenState extends ConsumerState<ProvisioningScreen> {
  final _controller = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(provisioningControllerProvider);

    return Scaffold(
      backgroundColor: Theme.of(context).brightness == Brightness.dark
          ? AppTheme.darkCanvas
          : Colors.white,
      body: GestureDetector(
        onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
        behavior: HitTestBehavior.opaque,
        child: CallbackShortcuts(
          bindings: <ShortcutActivator, VoidCallback>{
            const SingleActivator(LogicalKeyboardKey.escape): () {
              FocusManager.instance.primaryFocus?.unfocus();
            },
          },
          child: Focus(
            autofocus: true,
            child: _ActivationExperience(
              formKey: _formKey,
              controller: _controller,
              isLoading: state.isLoading,
              errorMessage: state.failure?.userMessage,
              onScan: () => _scan(context),
              onActivate: () => _activate(context),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _activate(BuildContext context) async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    final ok = await ref
        .read(provisioningControllerProvider.notifier)
        .activate(_controller.text);
    if (!ok || !context.mounted) {
      return;
    }
    context.go(RoutePaths.termsAgreement);
  }

  Future<void> _scan(BuildContext context) async {
    final scanned = await context.push<String>(RoutePaths.provisioningScanner);
    if (!context.mounted || scanned == null || scanned.trim().isEmpty) {
      return;
    }
    _controller.text = scanned;
    await _activate(context);
  }
}

bool get _prefersSetupLinkFirst {
  if (kIsWeb) {
    return true;
  }
  return switch (defaultTargetPlatform) {
    TargetPlatform.windows ||
    TargetPlatform.linux ||
    TargetPlatform.macOS => true,
    _ => false,
  };
}

double _provisioningHorizontalPadding(double width) {
  // Scale side inset with width so cards stay inset on phones
  // without getting cramped on very small screens.
  if (width < 360) {
    return 20;
  }
  if (width < 420) {
    return 28;
  }
  if (width < 600) {
    return 36;
  }
  if (width < 820) {
    return 48;
  }
  return ResponsiveBreakpoints.horizontalPadding(width) + 16;
}

/// Preferred line break matches the mockup; each half can still wrap
/// further on very narrow widths.
const _activationDescription =
    'Use the QR code or setup link from your\n'
    'administrator to get this phone activated';

class _ActivationExperience extends StatelessWidget {
  const _ActivationExperience({
    required this.formKey,
    required this.controller,
    required this.isLoading,
    required this.errorMessage,
    required this.onScan,
    required this.onActivate,
  });

  final GlobalKey<FormState> formKey;
  final TextEditingController controller;
  final bool isLoading;
  final String? errorMessage;
  final VoidCallback onScan;
  final VoidCallback onActivate;

  @override
  Widget build(BuildContext context) {
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;

    return SafeArea(
      child: Column(
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                final isWide = width >= 820;
                final horizontal = _provisioningHorizontalPadding(width);
                final content = Form(
                  key: formKey,
                  child: isWide
                      ? _WideActivationLayout(
                          controller: controller,
                          isLoading: isLoading,
                          errorMessage: errorMessage,
                          onScan: onScan,
                          onActivate: onActivate,
                        )
                      : _CompactActivationLayout(
                          controller: controller,
                          isLoading: isLoading,
                          errorMessage: errorMessage,
                          onScan: onScan,
                          onActivate: onActivate,
                        ),
                );

                return Scrollbar(
                  thumbVisibility: isWide,
                  child: SingleChildScrollView(
                    primary: true,
                    physics: const AlwaysScrollableScrollPhysics(),
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    padding: EdgeInsets.symmetric(
                      horizontal: horizontal,
                      vertical: isWide ? 32 : 20,
                    ),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: (constraints.maxHeight - (isWide ? 64 : 40))
                            .clamp(0.0, double.infinity),
                      ),
                      child: Align(
                        alignment: isWide
                            ? Alignment.center
                            : const Alignment(0, -0.18),
                        child: content,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          AnimatedOpacity(
            opacity: keyboardOpen ? 0 : 1,
            duration: const Duration(milliseconds: 180),
            child: IgnorePointer(
              ignoring: keyboardOpen,
              child: const Padding(
                padding: EdgeInsets.fromLTRB(24, 4, 24, 16),
                child: _PoweredByFooter(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CompactActivationLayout extends StatelessWidget {
  const _CompactActivationLayout({
    required this.controller,
    required this.isLoading,
    required this.errorMessage,
    required this.onScan,
    required this.onActivate,
  });

  final TextEditingController controller;
  final bool isLoading;
  final String? errorMessage;
  final VoidCallback onScan;
  final VoidCallback onActivate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _AppIcon(),
          const SizedBox(height: 36),
          Text(
            'Set up your calling app',
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineMedium?.copyWith(
              color: theme.colorScheme.onSurface,
              height: 1.15,
            ),
          ),
          const SizedBox(height: 18),
          Text(
            _activationDescription,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 64),
          _ActivationActions(
            controller: controller,
            isLoading: isLoading,
            errorMessage: errorMessage,
            onScan: onScan,
            onActivate: onActivate,
            expandSetupLinkInitially: _prefersSetupLinkFirst,
          ),
        ],
      ),
    );
  }
}

class _WideActivationLayout extends StatelessWidget {
  const _WideActivationLayout({
    required this.controller,
    required this.isLoading,
    required this.errorMessage,
    required this.onScan,
    required this.onActivate,
  });

  final TextEditingController controller;
  final bool isLoading;
  final String? errorMessage;
  final VoidCallback onScan;
  final VoidCallback onActivate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 980),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            flex: 11,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _AppIcon(alignment: Alignment.centerLeft, size: 84),
                  const SizedBox(height: 36),
                  Text(
                    'Set up your calling app',
                    style: theme.textTheme.headlineLarge?.copyWith(
                      color: theme.colorScheme.onSurface,
                      height: 1.1,
                    ),
                  ),
                  const SizedBox(height: 18),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 440),
                    child: Text(
                      _activationDescription,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        height: 1.45,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 28),
          Expanded(
            flex: 9,
            child: Align(
              alignment: Alignment.center,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: isDark
                        ? AppTheme.darkSurface.withValues(alpha: 0.72)
                        : theme.colorScheme.surface,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.08)
                          : theme.colorScheme.outline,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: AppTheme.brandBlack.withValues(
                          alpha: isDark ? 0.28 : 0.06,
                        ),
                        blurRadius: 28,
                        offset: const Offset(0, 14),
                      ),
                    ],
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(22, 24, 22, 24),
                    child: _ActivationActions(
                      controller: controller,
                      isLoading: isLoading,
                      errorMessage: errorMessage,
                      onScan: onScan,
                      onActivate: onActivate,
                      expandSetupLinkInitially: true,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ActivationActions extends StatelessWidget {
  const _ActivationActions({
    required this.controller,
    required this.isLoading,
    required this.errorMessage,
    required this.onScan,
    required this.onActivate,
    required this.expandSetupLinkInitially,
  });

  final TextEditingController controller;
  final bool isLoading;
  final String? errorMessage;
  final VoidCallback onScan;
  final VoidCallback onActivate;
  final bool expandSetupLinkInitially;

  @override
  Widget build(BuildContext context) {
    final setupLink = _SetupLinkSection(
      controller: controller,
      isLoading: isLoading,
      errorMessage: errorMessage,
      onActivate: onActivate,
      initiallyExpanded: expandSetupLinkInitially,
    );
    final scanCard = _OptionCard(
      icon: AppIcons.qrCode,
      label: isSupportedDesktopPlatform()
          ? 'Import QR code image'
          : 'Scan QR code',
      emphasized: true,
      onTap: isLoading ? null : onScan,
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (expandSetupLinkInitially) ...[
          setupLink,
          const SizedBox(height: 18),
          const _OrUseDivider(label: 'or'),
          const SizedBox(height: 18),
          scanCard,
        ] else ...[
          scanCard,
          const SizedBox(height: 18),
          const _OrUseDivider(),
          const SizedBox(height: 18),
          setupLink,
        ],
      ],
    );
  }
}

class _AppIcon extends StatelessWidget {
  const _AppIcon({this.alignment = Alignment.center, this.size = 72});

  final Alignment alignment;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Align(
      alignment: alignment,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: isDark ? AppTheme.darkSurface : Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isDark
                ? Colors.white.withValues(alpha: 0.06)
                : theme.colorScheme.outline.withValues(alpha: 0.85),
          ),
          boxShadow: [
            BoxShadow(
              color: AppTheme.brandBlack.withValues(
                alpha: isDark ? 0.35 : 0.08,
              ),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Center(child: AppBrandIcon(size: size)),
      ),
    );
  }
}

BoxDecoration _actionCardDecoration(BuildContext context) {
  final theme = Theme.of(context);
  final isDark = theme.brightness == Brightness.dark;

  return BoxDecoration(
    color: isDark ? AppTheme.darkSurface : Colors.white,
    borderRadius: BorderRadius.circular(14),
    border: Border.all(
      color: isDark
          ? Colors.white.withValues(alpha: 0.06)
          : theme.colorScheme.outline.withValues(alpha: 0.9),
    ),
    boxShadow: [
      BoxShadow(
        color: AppTheme.brandBlack.withValues(alpha: isDark ? 0.28 : 0.06),
        blurRadius: 16,
        offset: const Offset(0, 6),
      ),
    ],
  );
}

class _OptionCard extends StatelessWidget {
  const _OptionCard({
    required this.icon,
    required this.label,
    required this.onTap,
    this.emphasized = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = onTap != null;
    final accent = emphasized
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;
    final muted = theme.colorScheme.onSurfaceVariant;

    return DecoratedBox(
      decoration: _actionCardDecoration(context),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          mouseCursor: enabled
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 22,
                  color: enabled ? accent : muted.withValues(alpha: 0.5),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    label,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: enabled
                          ? theme.colorScheme.onSurface
                          : muted.withValues(alpha: 0.6),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Icon(
                  AppIcons.chevronRight,
                  size: 20,
                  color: enabled ? accent : muted.withValues(alpha: 0.5),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _OrUseDivider extends StatelessWidget {
  const _OrUseDivider({this.label = 'or use'});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lineColor = theme.colorScheme.outline.withValues(alpha: 0.85);

    return Row(
      children: [
        Expanded(child: Divider(color: lineColor, height: 1)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        Expanded(child: Divider(color: lineColor, height: 1)),
      ],
    );
  }
}

class _SetupLinkSection extends StatefulWidget {
  const _SetupLinkSection({
    required this.controller,
    required this.isLoading,
    required this.errorMessage,
    required this.onActivate,
    this.initiallyExpanded = false,
  });

  final TextEditingController controller;
  final bool isLoading;
  final String? errorMessage;
  final VoidCallback onActivate;
  final bool initiallyExpanded;

  @override
  State<_SetupLinkSection> createState() => _SetupLinkSectionState();
}

class _SetupLinkSectionState extends State<_SetupLinkSection> {
  static const _expandDuration = Duration(milliseconds: 220);

  final _focusNode = FocusNode();
  late var _expanded = widget.initiallyExpanded;

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  void _expand() {
    if (_expanded || widget.isLoading) {
      return;
    }
    setState(() => _expanded = true);
    Future<void>.delayed(_expandDuration, () {
      if (mounted) {
        _focusNode.requestFocus();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: _actionCardDecoration(context),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: AnimatedCrossFade(
          duration: _expandDuration,
          sizeCurve: Curves.easeOutCubic,
          firstCurve: Curves.easeOutCubic,
          secondCurve: Curves.easeOutCubic,
          crossFadeState: _expanded
              ? CrossFadeState.showSecond
              : CrossFadeState.showFirst,
          alignment: Alignment.topCenter,
          firstChild: _SetupLinkCollapsed(
            onTap: widget.isLoading ? null : _expand,
          ),
          secondChild: _SetupLinkExpanded(
            controller: widget.controller,
            focusNode: _focusNode,
            isLoading: widget.isLoading,
            errorMessage: widget.errorMessage,
            onActivate: widget.onActivate,
          ),
        ),
      ),
    );
  }
}

class _SetupLinkCollapsed extends StatelessWidget {
  const _SetupLinkCollapsed({required this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final enabled = onTap != null;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        mouseCursor: enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
          child: Row(
            children: [
              Icon(
                AppIcons.link,
                size: 22,
                color: enabled ? muted : muted.withValues(alpha: 0.5),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  'Setup link',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: enabled
                        ? theme.colorScheme.onSurface
                        : muted.withValues(alpha: 0.6),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Icon(
                AppIcons.chevronRight,
                size: 20,
                color: enabled ? muted : muted.withValues(alpha: 0.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SetupLinkExpanded extends StatelessWidget {
  const _SetupLinkExpanded({
    required this.controller,
    required this.focusNode,
    required this.isLoading,
    required this.errorMessage,
    required this.onActivate,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool isLoading;
  final String? errorMessage;
  final VoidCallback onActivate;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextFormField(
            controller: controller,
            focusNode: focusNode,
            enabled: !isLoading,
            minLines: 1,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Setup link',
              hintText: 'Paste setup link',
              prefixIcon: Icon(AppIcons.link),
            ),
            textInputAction: TextInputAction.done,
            validator: (value) => value == null || value.trim().isEmpty
                ? 'Activation link is required'
                : null,
            onFieldSubmitted: (_) => onActivate(),
          ),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            child: errorMessage == null
                ? const SizedBox.shrink()
                : Padding(
                    key: ValueKey(errorMessage),
                    padding: const EdgeInsets.only(top: 12),
                    child: _ActivationError(message: errorMessage!),
                  ),
          ),
          const SizedBox(height: 14),
          FilledButton(
            onPressed: isLoading ? null : onActivate,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: isLoading
                  ? const SizedBox(
                      key: ValueKey('loading'),
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text('Activate', key: ValueKey('activate')),
            ),
          ),
        ],
      ),
    );
  }
}

class _PoweredByFooter extends StatelessWidget {
  const _PoweredByFooter();

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(
      color: Theme.of(
        context,
      ).colorScheme.onSurfaceVariant.withValues(alpha: 0.75),
      fontWeight: FontWeight.w500,
      letterSpacing: 0.1,
      fontSize: 12.5,
    );
    final markSize = (style?.fontSize ?? 11) * 0.72;

    return Text.rich(
      TextSpan(
        style: style,
        children: [
          const TextSpan(text: 'Powered by ThinkSwift'),
          WidgetSpan(
            alignment: PlaceholderAlignment.top,
            child: Padding(
              padding: const EdgeInsets.only(left: 1),
              child: Text(
                '®',
                style: style?.copyWith(fontSize: markSize, height: 1),
              ),
            ),
          ),
        ],
      ),
      textAlign: TextAlign.center,
    );
  }
}

class _ActivationError extends StatelessWidget {
  const _ActivationError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.error.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: theme.colorScheme.error.withValues(alpha: 0.18),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(AppIcons.warning, color: theme.colorScheme.error, size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
