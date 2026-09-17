import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/route_names.dart';
import '../../../app/theme/app_theme.dart';
import '../../../shared/icons/app_icons.dart';
import '../../../voip/platform/proximity_screen_control.dart';
import '../../contacts/presentation/contacts_providers.dart';
import '../../directory/presentation/directory_providers.dart';
import '../../dialer/presentation/dialer_input_platform.dart';
import '../../session/presentation/session_controller.dart';
import '../domain/audio_output_route.dart';
import '../domain/call_quality_info.dart';
import '../domain/call_status.dart';
import '../domain/voip_call.dart';
import 'audio_route_picker.dart';
import 'call_quality_sheet.dart';
import 'call_session_providers.dart';
import 'caller_avatar.dart';
import 'caller_identity.dart';

/// In-call controls hosted by the Dial tab (and ActiveCallScreen fallback).
class InCallPanel extends ConsumerStatefulWidget {
  const InCallPanel({
    required this.call,
    this.enableProximity = true,
    super.key,
  });

  final VoipCall call;
  final bool enableProximity;

  @override
  ConsumerState<InCallPanel> createState() => _InCallPanelState();
}

class _InCallPanelState extends ConsumerState<InCallPanel> {
  static const _dtmfKeys = [
    ('1', ''),
    ('2', 'ABC'),
    ('3', 'DEF'),
    ('4', 'GHI'),
    ('5', 'JKL'),
    ('6', 'MNO'),
    ('7', 'PQRS'),
    ('8', 'TUV'),
    ('9', 'WXYZ'),
    ('*', ''),
    ('0', ''),
    ('#', ''),
  ];

  final _proximity = const ProximityScreenControl();
  final _dtmfKeyboardFocus = FocusNode(debugLabel: 'in-call-dtmf-keypad');
  bool _proximityEnabled = false;
  bool _showKeypad = false;
  String _dtmfBuffer = '';
  CallQualityInfo? _quality;
  Timer? _qualityTimer;

  @override
  void initState() {
    super.initState();
    if (_canReadQuality(widget.call.status)) {
      _refreshQuality();
    }
    _qualityTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      _refreshQuality();
    });
  }

  @override
  void didUpdateWidget(covariant InCallPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.call.id != widget.call.id) {
      _quality = null;
    }
    if (_canReadQuality(widget.call.status) &&
        (oldWidget.call.id != widget.call.id ||
            !_canReadQuality(oldWidget.call.status))) {
      _refreshQuality();
    }
  }

  @override
  void dispose() {
    _qualityTimer?.cancel();
    _dtmfKeyboardFocus.dispose();
    _setProximity(false);
    super.dispose();
  }

  Future<void> _refreshQuality() async {
    final active = ref.read(activeCallProvider).value;
    final call = isInCallUiCall(active) ? active! : widget.call;
    // Linphone's RTP/RTCP statistics are not valid before media streams exist.
    // Some iOS SDK builds access an uninitialised native stats object when
    // queried during IncomingReceived/OutgoingProgress, which can terminate
    // the process instead of returning an ordinary Swift error.
    if (!_canReadQuality(call.status)) {
      return;
    }
    try {
      final info = await ref
          .read(sipServiceProvider)
          .getCallQuality(callId: call.id);
      if (!mounted) return;
      setState(() => _quality = info);
    } catch (_) {
      // Keep the last known reading; quality is best-effort.
    }
  }

  bool _canReadQuality(CallStatus status) {
    return status == CallStatus.active || status == CallStatus.held;
  }

  @override
  Widget build(BuildContext context) {
    // Prefer the live session call so keypad ↔ controls share the same
    // mute / audio-route state without relying on a stale widget snapshot.
    final live = ref.watch(activeCallProvider).value;
    // Only one VoIP call is supported. Linphone may promote its temporary
    // object ID to the SIP Call-ID after this widget was created, so the live
    // provider snapshot is always the authoritative control target.
    final call = isInCallUiCall(live) ? live! : widget.call;
    final contacts = ref.watch(contactsProvider).value ?? const [];
    final directory = ref.watch(directoryProvider).value ?? const [];
    final calls = ref.watch(liveCallsProvider).value ?? const <VoipCall>[];
    VoipCall? heldCall;
    for (final candidate in calls) {
      if (candidate.id != call.id && candidate.status == CallStatus.held) {
        heldCall = candidate;
        break;
      }
    }
    final identity = resolveCallerIdentity(
      call: call,
      contacts: contacts,
      directory: directory,
    );
    final displayName = identity.label;
    final heldIdentity = heldCall == null
        ? null
        : resolveCallerIdentity(
            call: heldCall,
            contacts: contacts,
            directory: directory,
          );

    ref.listen(activeCallProvider, (_, next) {
      next.whenData((liveCall) {
        if (!widget.enableProximity ||
            liveCall == null ||
            !isInCallUiCall(liveCall) ||
            _showKeypad) {
          _setProximity(false);
          return;
        }
        _setProximity(liveCall.audioRoute == AudioOutputRoute.earpiece);
      });
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!widget.enableProximity || _showKeypad) {
        _setProximity(false);
        return;
      }
      _setProximity(call.audioRoute == AudioOutputRoute.earpiece);
    });

    final acceptsKeyboardInput = supportsDesktopDialerKeyboard();
    return Focus(
      focusNode: _dtmfKeyboardFocus,
      autofocus: acceptsKeyboardInput,
      onKeyEvent: acceptsKeyboardInput ? _handleDtmfKeyEvent : null,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        child: _showKeypad
            ? KeyedSubtree(
                key: const ValueKey('in-call-keypad'),
                child: _buildKeypad(context, call, displayName),
              )
            : KeyedSubtree(
                key: const ValueKey('in-call-controls'),
                child: _buildControls(
                  context,
                  call,
                  identity,
                  displayName,
                  heldCall: heldCall,
                  heldIdentity: heldIdentity,
                ),
              ),
      ),
    );
  }

  Widget _buildControls(
    BuildContext context,
    VoipCall call,
    CallerIdentity identity,
    String displayName, {
    VoipCall? heldCall,
    CallerIdentity? heldIdentity,
  }) {
    final theme = Theme.of(context);
    final quality = _quality;
    final qualityScore = quality?.currentQuality;
    final qualityColor = _qualityColor(qualityScore);
    final qualityLabel = quality?.qualityLabel ?? 'Checking…';
    final bars = _qualityBars(qualityScore);

    return Stack(
      children: [
        Column(
          children: [
            const SizedBox(height: 40),
            const Spacer(flex: 2),
            CallerAvatar(identity: identity, radius: 56),
            const SizedBox(height: 22),
            Text(
              displayName,
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineMedium?.copyWith(
                fontFamily: AppTheme.bodyFontFamily,
                fontWeight: FontWeight.w700,
                letterSpacing: 0,
              ),
            ),
            if (identity.isResolvedName &&
                identity.number.isNotEmpty &&
                identity.number != displayName) ...[
              const SizedBox(height: 6),
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
            const SizedBox(height: 8),
            Text(
              _statusLabel(call.status),
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w600,
                letterSpacing: 0,
              ),
            ),
            if (heldCall != null && heldIdentity != null) ...[
              const SizedBox(height: 14),
              _HeldCallCard(
                label: heldIdentity.label,
                onSwap: () => unawaited(_swapToCall(heldCall.id)),
              ),
            ],
            const Spacer(flex: 2),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _CallAction(
                  icon: call.isMuted ? AppIcons.muteOff : AppIcons.muteOn,
                  label: 'Mute',
                  selected: call.isMuted,
                  onPressed: () => unawaited(_setMuted(call)),
                ),
                const SizedBox(width: 22),
                _AudioRouteAction(
                  route: call.audioRoute,
                  onPressed: () => showAudioRoutePicker(
                    context: context,
                    ref: ref,
                    selectedRoute: call.audioRoute,
                  ),
                ),
                const SizedBox(width: 22),
                _CallAction(
                  icon: AppIcons.hold,
                  label: 'Hold',
                  selected: call.status == CallStatus.held,
                  onPressed: () async {
                    final service = ref.read(sipServiceProvider);
                    final messenger = ScaffoldMessenger.of(context);
                    final resuming = call.status == CallStatus.held;
                    try {
                      if (resuming) {
                        await service.resume(call.id);
                      } else {
                        await service.hold(call.id);
                      }
                    } catch (_) {
                      messenger.showSnackBar(
                        SnackBar(
                          content: Text(
                            resuming
                                ? 'Unable to resume call.'
                                : 'Unable to hold call.',
                          ),
                        ),
                      );
                      await service.syncCurrentCall();
                    }
                  },
                ),
              ],
            ),
            const SizedBox(height: 22),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _CallAction(
                  icon: AppIcons.navDialer,
                  label: 'Dialpad',
                  onPressed: () => setState(() {
                    _showKeypad = true;
                    _setProximity(false);
                  }),
                ),
                if (ref
                        .watch(sessionControllerProvider)
                        .value
                        ?.directoryAccess !=
                    null) ...[
                  const SizedBox(width: 22),
                  _CallAction(
                    icon: AppIcons.callForward,
                    label: 'Transfer',
                    onPressed: () {
                      ref.read(callTransferModeProvider.notifier).begin();
                      context.go(RoutePaths.directory);
                    },
                  ),
                ],
              ],
            ),
            const Spacer(flex: 2),
            _EndCallButton(onPressed: () => unawaited(_endCall(call))),
            const Spacer(),
          ],
        ),
        Positioned(
          top: 8,
          left: 0,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _SignalBars(
                activeBars: bars,
                color: qualityColor,
                inactiveColor: theme.colorScheme.onSurfaceVariant.withValues(
                  alpha: 0.28,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                qualityLabel,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: qualityColor,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0,
                ),
              ),
            ],
          ),
        ),
        Positioned(
          top: 0,
          right: 0,
          child: IconButton(
            tooltip: 'Call quality details',
            onPressed: () => showCallQualitySheet(
              context: context,
              ref: ref,
              callId: call.id,
            ),
            icon: const Icon(AppIcons.info),
          ),
        ),
      ],
    );
  }

  Widget _buildKeypad(BuildContext context, VoipCall call, String displayName) {
    final theme = Theme.of(context);
    final digits = _dtmfBuffer.isEmpty ? displayName : _dtmfBuffer;
    return Column(
      children: [
        const SizedBox(height: 36),
        Text(
          digits,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: AppTheme.numberStyle(
            theme.textTheme.headlineSmall,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 28),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final maxWidth = constraints.maxWidth.clamp(0.0, 340.0);
              final height = constraints.maxHeight;
              // Keep keys circular-ish and fully visible on short screens.
              final cell = (maxWidth / 3).clamp(56.0, 92.0);
              final spacing = height < 340 ? 8.0 : 12.0;
              final gridHeight = cell * 4 + spacing * 3;
              final scale = gridHeight > height && height > 0
                  ? height / gridHeight
                  : 1.0;
              final keySize = (cell * scale).clamp(48.0, 92.0);
              final gap = (spacing * scale).clamp(6.0, 12.0);

              return Center(
                child: SizedBox(
                  width: keySize * 3 + gap * 2,
                  child: GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: _dtmfKeys.length,
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      mainAxisSpacing: gap,
                      crossAxisSpacing: gap,
                      mainAxisExtent: keySize,
                    ),
                    itemBuilder: (context, index) {
                      final (value, letters) = _dtmfKeys[index];
                      return _DtmfKey(
                        value: value,
                        letters: letters,
                        compact: keySize < 70,
                        onPressed: () => _sendDtmf(value),
                      );
                    },
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 8),
        // Phone.app-style footer: Hide left, End centered, Audio right.
        SizedBox(
          height: 96,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(left: 12),
                  child: _CallAction(
                    icon: AppIcons.keypad,
                    label: 'Hide',
                    onPressed: () => setState(() => _showKeypad = false),
                  ),
                ),
              ),
              _EndCallButton(onPressed: () => unawaited(_endCall(call))),
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: _AudioRouteAction(
                    route: call.audioRoute,
                    onPressed: () => showAudioRoutePicker(
                      context: context,
                      ref: ref,
                      selectedRoute: call.audioRoute,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  KeyEventResult _handleDtmfKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed ||
        keyboard.isMetaPressed ||
        keyboard.isAltPressed) {
      return KeyEventResult.ignored;
    }

    if (event.logicalKey == LogicalKeyboardKey.escape) {
      setState(() => _showKeypad = false);
      return KeyEventResult.handled;
    }

    final value = dtmfCharacterFromKeyboard(event.character);
    if (value == null) return KeyEventResult.ignored;
    if (!_showKeypad) {
      setState(() => _showKeypad = true);
      _setProximity(false);
    }
    _sendDtmf(value);
    return KeyEventResult.handled;
  }

  void _sendDtmf(String value) {
    setState(() => _dtmfBuffer = '$_dtmfBuffer$value');
    ref.read(sipServiceProvider).sendDtmf(value);
  }

  Future<void> _setMuted(VoipCall call) async {
    try {
      await ref.read(sipServiceProvider).mute(!call.isMuted);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unable to change mute state.')),
      );
      await ref.read(sipServiceProvider).syncCurrentCall();
    }
  }

  Future<void> _endCall(VoipCall call) async {
    try {
      await ref.read(sipServiceProvider).endCall(call.id);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unable to end call. Please try again.')),
      );
      await ref.read(sipServiceProvider).syncCurrentCall();
    }
  }

  Future<void> _swapToCall(String callId) async {
    try {
      await ref.read(sipServiceProvider).switchToCall(callId);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Unable to switch calls. Please try again.'),
        ),
      );
      await ref.read(sipServiceProvider).syncCurrentCall();
    }
  }

  void _setProximity(bool enabled) {
    if (_proximityEnabled == enabled) {
      return;
    }
    _proximityEnabled = enabled;
    unawaited(_proximity.setEnabled(enabled));
  }

  String _statusLabel(CallStatus status) {
    return switch (status) {
      CallStatus.ringing => 'Ringing',
      CallStatus.dialing => 'Calling',
      CallStatus.connecting => 'Connecting',
      CallStatus.active => 'Connected',
      CallStatus.held => 'On hold',
      CallStatus.ended => 'Ended',
      CallStatus.missed => 'Missed',
      CallStatus.failed => 'Failed',
    };
  }
}

class _HeldCallCard extends StatelessWidget {
  const _HeldCallCard({required this.label, required this.onSwap});

  final String label;
  final VoidCallback onSwap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Material(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onSwap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Icon(AppIcons.hold, color: theme.colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('On hold', style: theme.textTheme.labelMedium),
                      Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Icon(AppIcons.swapCalls, color: theme.colorScheme.primary),
                const SizedBox(width: 6),
                Text(
                  'Swap',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Color _qualityColor(double? score) {
  if (score == null || score < 0) {
    return const Color(0xFF9CA3AF);
  }
  if (score >= 4) return const Color(0xFF16A34A);
  if (score >= 3) return const Color(0xFFF59E0B);
  return const Color(0xFFDC2626);
}

/// Maps MOS (1–5) to 0–4 cellular-style bars.
int _qualityBars(double? score) {
  if (score == null || score < 0) return 0;
  if (score >= 4) return 4;
  if (score >= 3) return 3;
  if (score >= 2) return 2;
  if (score >= 1) return 1;
  return 0;
}

class _SignalBars extends StatelessWidget {
  const _SignalBars({
    required this.activeBars,
    required this.color,
    required this.inactiveColor,
  });

  final int activeBars;
  final Color color;
  final Color inactiveColor;

  static const _heights = [6.0, 10.0, 14.0, 18.0];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 22,
      height: 18,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 0; i < 4; i++) ...[
            if (i > 0) const SizedBox(width: 2),
            Expanded(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                height: _heights[i],
                decoration: BoxDecoration(
                  color: i < activeBars ? color : inactiveColor,
                  borderRadius: BorderRadius.circular(1.5),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _EndCallButton extends StatelessWidget {
  const _EndCallButton({required this.onPressed});

  static const _endCallRed = Color(0xFFDC2626);

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: _endCallRed,
        foregroundColor: Colors.white,
        disabledBackgroundColor: _endCallRed.withValues(alpha: 0.45),
        disabledForegroundColor: Colors.white,
        minimumSize: const Size(72, 72),
        shape: const CircleBorder(),
      ),
      child: const Icon(AppIcons.callEnd, size: 28),
    );
  }
}

class _DtmfKey extends StatelessWidget {
  const _DtmfKey({
    required this.value,
    required this.letters,
    required this.onPressed,
    this.compact = false,
  });

  final String value;
  final String letters;
  final VoidCallback onPressed;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: AppTheme.sheetControlBackground(theme.brightness),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                value,
                style: AppTheme.numberStyle(
                  compact
                      ? theme.textTheme.headlineSmall
                      : theme.textTheme.headlineMedium,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (letters.isNotEmpty)
                Text(
                  letters,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                    fontSize: compact ? 9 : 11,
                    letterSpacing: 0.6,
                    height: 1,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CallAction extends StatelessWidget {
  const _CallAction({
    required this.icon,
    required this.label,
    this.selected = false,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SizedBox(
      width: 76,
      child: Column(
        children: [
          IconButton(
            tooltip: label,
            onPressed: onPressed,
            icon: Icon(icon),
            style: IconButton.styleFrom(
              fixedSize: const Size(64, 64),
              backgroundColor: selected
                  ? theme.colorScheme.primary
                  : AppTheme.sheetControlBackground(theme.brightness),
              foregroundColor: selected
                  ? theme.colorScheme.onPrimary
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              letterSpacing: 0,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

/// Keeps the same app-owned audio icon on every platform. On iOS a transparent,
/// non-subclassed AVRoutePickerView is the actual tap target, so Apple owns the
/// output list and route transition while Flutter owns only the artwork.
class _AudioRouteAction extends StatelessWidget {
  const _AudioRouteAction({required this.route, required this.onPressed});

  final AudioOutputRoute route;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      final theme = Theme.of(context);
      final selected = route != AudioOutputRoute.earpiece;
      return SizedBox(
        width: 76,
        child: Column(
          children: [
            SizedBox.square(
              dimension: 64,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  IgnorePointer(
                    child: IconButton(
                      tooltip: 'Audio',
                      onPressed: () {},
                      icon: Icon(_audioRouteIcon(route)),
                      style: IconButton.styleFrom(
                        fixedSize: const Size(64, 64),
                        backgroundColor: selected
                            ? theme.colorScheme.primary
                            : AppTheme.sheetControlBackground(theme.brightness),
                        foregroundColor: selected
                            ? theme.colorScheme.onPrimary
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const UiKitView(viewType: 'voipcloud/audio_route_picker'),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Audio',
              maxLines: 1,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                letterSpacing: 0,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    return _CallAction(
      icon: _audioRouteIcon(route),
      label: 'Audio',
      selected: route != AudioOutputRoute.earpiece,
      onPressed: onPressed,
    );
  }
}

IconData _audioRouteIcon(AudioOutputRoute route) {
  return switch (route) {
    AudioOutputRoute.earpiece => AppIcons.call,
    AudioOutputRoute.speaker => AppIcons.speakerOn,
    AudioOutputRoute.bluetooth => AppIcons.bluetooth,
    AudioOutputRoute.wired => Icons.headphones_rounded,
    AudioOutputRoute.streaming => Icons.devices_rounded,
  };
}
