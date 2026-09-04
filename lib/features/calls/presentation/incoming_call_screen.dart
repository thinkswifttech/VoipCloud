import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/route_names.dart';
import '../../../app/theme/app_theme.dart';
import '../../../shared/icons/app_icons.dart';
import '../../../shared/platform/desktop_platform.dart';
import '../../contacts/presentation/contacts_providers.dart';
import '../../directory/presentation/directory_providers.dart';
import '../domain/call_direction.dart';
import '../domain/call_status.dart';
import '../../session/presentation/session_controller.dart';
import 'caller_identity.dart';
import 'caller_avatar.dart';

class IncomingCallScreen extends ConsumerStatefulWidget {
  const IncomingCallScreen({required this.callId, super.key});

  final String callId;

  static const _answerColor = Color(0xFF16A34A);
  static const _rejectColor = Color(0xFFDC2626);

  @override
  ConsumerState<IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends ConsumerState<IncomingCallScreen> {
  var _isCompletingAction = false;

  @override
  void initState() {
    super.initState();
    if (isSupportedDesktopPlatform()) {
      HardwareKeyboard.instance.addHandler(_handleDesktopKeyEvent);
    }
  }

  @override
  void dispose() {
    if (isSupportedDesktopPlatform()) {
      HardwareKeyboard.instance.removeHandler(_handleDesktopKeyEvent);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final useDesktopControls = isSupportedDesktopPlatform();

    ref.listen(activeCallProvider, (_, next) {
      next.whenData((call) {
        final isThisCallStillRinging =
            call != null &&
            call.id == widget.callId &&
            call.direction == CallDirection.incoming &&
            call.status == CallStatus.ringing;
        if (!isThisCallStillRinging && context.mounted) {
          context.go(RoutePaths.dialer);
        }
      });
    });

    final call = ref.watch(activeCallProvider).value;
    final contacts = ref.watch(contactsProvider).value ?? const [];
    final directory = ref.watch(directoryProvider).value ?? const [];
    final identity = resolveCallerIdentity(
      call: call,
      contacts: contacts,
      directory: directory,
    );
    final caller = identity.label;

    final screen = Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 38),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const SizedBox(height: 18),
                  Text(
                    'Incoming call',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      letterSpacing: 0,
                    ),
                  ),
                  const Spacer(flex: 2),
                  CallerAvatar(identity: identity, radius: 62),
                  const SizedBox(height: 28),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: Text(
                      caller,
                      textAlign: TextAlign.center,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.headlineMedium?.copyWith(
                        fontFamily: AppTheme.bodyFontFamily,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0,
                      ),
                    ),
                  ),
                  if (identity.isResolvedName &&
                      identity.number.isNotEmpty &&
                      identity.number != caller) ...[
                    const SizedBox(height: 8),
                    Text(
                      identity.number,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppTheme.numberStyle(
                        theme.textTheme.titleMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 14),
                  Text(
                    useDesktopControls
                        ? 'Answer with Enter or decline with Esc'
                        : 'Swipe right to answer or left to decline',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      letterSpacing: 0,
                    ),
                  ),
                  const Spacer(flex: 3),
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: useDesktopControls ? 520 : 420,
                    ),
                    child: useDesktopControls
                        ? _DesktopIncomingCallActions(
                            enabled: !_isCompletingAction,
                            onAnswer: () => unawaited(_answer(context)),
                            onDecline: () => unawaited(_reject(context)),
                          )
                        : _IncomingCallSlider(
                            enabled: !_isCompletingAction,
                            answerColor: IncomingCallScreen._answerColor,
                            declineColor: IncomingCallScreen._rejectColor,
                            onAnswer: () => unawaited(_answer(context)),
                            onDecline: () => unawaited(_reject(context)),
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    if (!useDesktopControls) return screen;
    return Focus(autofocus: true, child: screen);
  }

  bool _handleDesktopKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent || _isCompletingAction || !mounted) {
      return false;
    }

    switch (event.logicalKey) {
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
        unawaited(_answer(context));
        return true;
      case LogicalKeyboardKey.escape:
        unawaited(_reject(context));
        return true;
    }
    return false;
  }

  Future<void> _answer(BuildContext context) async {
    if (_isCompletingAction) return;
    setState(() => _isCompletingAction = true);
    try {
      await ref.read(sipServiceProvider).acceptCall(widget.callId);
      if (context.mounted) {
        context.go(RoutePaths.dialer);
      }
    } catch (_) {
      if (!context.mounted) return;
      setState(() => _isCompletingAction = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not answer the call. Please try again.'),
        ),
      );
    }
  }

  Future<void> _reject(BuildContext context) async {
    if (_isCompletingAction) return;
    setState(() => _isCompletingAction = true);
    await ref.read(sipServiceProvider).rejectCall(widget.callId);
    if (context.mounted) {
      context.go(RoutePaths.dialer);
    }
  }
}

class _DesktopIncomingCallActions extends StatelessWidget {
  const _DesktopIncomingCallActions({
    required this.enabled,
    required this.onAnswer,
    required this.onDecline,
  });

  final bool enabled;
  final VoidCallback onAnswer;
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: SizedBox(
            height: 64,
            child: FilledButton.icon(
              onPressed: enabled ? onDecline : null,
              style: FilledButton.styleFrom(
                backgroundColor: IncomingCallScreen._rejectColor,
                foregroundColor: Colors.white,
              ),
              icon: const Icon(AppIcons.callEnd),
              label: const Text('Decline  ·  Esc'),
            ),
          ),
        ),
        const SizedBox(width: 18),
        Expanded(
          child: SizedBox(
            height: 64,
            child: FilledButton.icon(
              autofocus: true,
              onPressed: enabled ? onAnswer : null,
              style: FilledButton.styleFrom(
                backgroundColor: IncomingCallScreen._answerColor,
                foregroundColor: Colors.white,
              ),
              icon: const Icon(AppIcons.call),
              label: const Text('Answer  ·  Enter'),
            ),
          ),
        ),
      ],
    );
  }
}

class _IncomingCallSlider extends StatefulWidget {
  const _IncomingCallSlider({
    required this.enabled,
    required this.answerColor,
    required this.declineColor,
    required this.onAnswer,
    required this.onDecline,
  });

  final bool enabled;
  final Color answerColor;
  final Color declineColor;
  final VoidCallback onAnswer;
  final VoidCallback onDecline;

  @override
  State<_IncomingCallSlider> createState() => _IncomingCallSliderState();
}

class _IncomingCallSliderState extends State<_IncomingCallSlider>
    with SingleTickerProviderStateMixin {
  static const _height = 86.0;
  static const _thumbSize = 70.0;
  static const _horizontalPadding = 8.0;
  static const _triggerProgress = 0.72;

  var _dragOffset = 0.0;
  var _isDragging = false;
  late final AnimationController _ringController;

  @override
  void initState() {
    super.initState();
    _ringController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat();
  }

  @override
  void dispose() {
    _ringController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.clamp(280.0, 420.0);
        final travel = (width - _thumbSize - (_horizontalPadding * 2)) / 2;
        final progress = travel == 0
            ? 0.0
            : (_dragOffset / travel).clamp(-1.0, 1.0);
        final actionColor = progress >= 0
            ? widget.answerColor
            : widget.declineColor;
        final backgroundColor = Color.lerp(
          const Color(0xFF30333D),
          actionColor,
          progress.abs() * 0.86,
        )!;
        final thumbIconColor = Color.lerp(
          theme.colorScheme.primary,
          actionColor,
          progress.abs(),
        )!;

        return Center(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: widget.enabled
                ? (_) => setState(() => _isDragging = true)
                : null,
            onHorizontalDragUpdate: widget.enabled
                ? (details) {
                    setState(() {
                      _dragOffset = (_dragOffset + details.delta.dx).clamp(
                        -travel,
                        travel,
                      );
                    });
                  }
                : null,
            onHorizontalDragEnd: widget.enabled
                ? (_) => _finishDrag(progress)
                : null,
            onHorizontalDragCancel: widget.enabled ? _resetDrag : null,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOutCubic,
              width: width,
              height: _height,
              decoration: BoxDecoration(
                color: backgroundColor,
                borderRadius: BorderRadius.circular(_height / 2),
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Positioned.fill(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 28),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          _SliderLabel(
                            label: 'Decline',
                            alignment: Alignment.centerLeft,
                            isActive: progress < -0.22,
                          ),
                          _SliderLabel(
                            label: 'Answer',
                            alignment: Alignment.centerRight,
                            isActive: progress > 0.22,
                          ),
                        ],
                      ),
                    ),
                  ),
                  AnimatedSlide(
                    duration: _isDragging
                        ? Duration.zero
                        : const Duration(milliseconds: 180),
                    curve: Curves.easeOutCubic,
                    offset: Offset(_dragOffset / _thumbSize, 0),
                    child: AnimatedBuilder(
                      animation: _ringController,
                      builder: (context, child) {
                        final reduceMotion = MediaQuery.of(
                          context,
                        ).disableAnimations;
                        final ringProgress = _ringController.value;
                        final burst = ringProgress < 0.32
                            ? 1 - (ringProgress / 0.32)
                            : 0.0;
                        final wave =
                            math.sin(ringProgress * math.pi * 8) * burst;
                        final shouldRing =
                            !_isDragging && progress.abs() < 0.08;
                        return Transform.translate(
                          offset: Offset(
                            reduceMotion || !shouldRing ? 0 : wave * 2.8,
                            0,
                          ),
                          child: Transform.rotate(
                            angle: reduceMotion || !shouldRing
                                ? 0
                                : wave * 0.05,
                            child: child,
                          ),
                        );
                      },
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 140),
                        width: _thumbSize,
                        height: _thumbSize,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(_thumbSize / 2),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.18),
                              blurRadius: 18,
                              offset: const Offset(0, 8),
                            ),
                          ],
                        ),
                        child: Icon(
                          progress < -0.35 ? AppIcons.callEnd : AppIcons.call,
                          color: thumbIconColor,
                          size: 30,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _finishDrag(double progress) {
    if (progress >= _triggerProgress) {
      widget.onAnswer();
      return;
    }

    if (progress <= -_triggerProgress) {
      widget.onDecline();
      return;
    }

    _resetDrag();
  }

  void _resetDrag() {
    if (!mounted) return;
    setState(() {
      _dragOffset = 0;
      _isDragging = false;
    });
  }
}

class _SliderLabel extends StatelessWidget {
  const _SliderLabel({
    required this.label,
    required this.alignment,
    required this.isActive,
  });

  final String label;
  final Alignment alignment;
  final bool isActive;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AnimatedOpacity(
      duration: const Duration(milliseconds: 140),
      opacity: isActive ? 1 : 0.78,
      child: Align(
        alignment: alignment,
        child: Text(
          label,
          style: theme.textTheme.labelLarge?.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.w700,
            letterSpacing: 0,
          ),
        ),
      ),
    );
  }
}
