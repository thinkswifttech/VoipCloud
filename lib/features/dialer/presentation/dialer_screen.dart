import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/route_names.dart';
import '../../../app/theme/app_theme.dart';
import '../../../core/errors/app_exception.dart';
import '../../../shared/icons/app_icons.dart';
import '../../../shared/widgets/help_support_sheet.dart';
import '../../../shared/widgets/page_content.dart';
import '../../../shared/widgets/responsive.dart';
import '../../auth/presentation/auth_providers.dart';
import '../../calls/presentation/call_session_providers.dart';
import '../../calls/presentation/in_call_panel.dart';
import '../../session/presentation/session_controller.dart';
import '../../settings/presentation/settings_controller.dart';
import '../../sip/domain/sip_registration_state.dart';
import 'dialer_controller.dart';
import 'dialer_input_platform.dart';

class DialerScreen extends ConsumerStatefulWidget {
  const DialerScreen({this.initialDestination, super.key});

  final String? initialDestination;

  static const _keys = [
    _DialKey('1', '', icon: AppIcons.voicemail),
    _DialKey('2', 'ABC'),
    _DialKey('3', 'DEF'),
    _DialKey('4', 'GHI'),
    _DialKey('5', 'JKL'),
    _DialKey('6', 'MNO'),
    _DialKey('7', 'PQRS'),
    _DialKey('8', 'TUV'),
    _DialKey('9', 'WXYZ'),
    _DialKey('*', ''),
    _DialKey('0', '+'),
    _DialKey('#', ''),
  ];

  @override
  ConsumerState<DialerScreen> createState() => _DialerScreenState();
}

class _DialerScreenState extends ConsumerState<DialerScreen> {
  final _destinationController = TextEditingController();
  final _destinationFocus = FocusNode();
  int? _pendingCursor;

  @override
  void initState() {
    super.initState();
    _applyInitialDestination(widget.initialDestination);
    HardwareKeyboard.instance.addHandler(_handleDesktopDialKey);
  }

  @override
  void didUpdateWidget(covariant DialerScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialDestination != oldWidget.initialDestination) {
      _applyInitialDestination(widget.initialDestination);
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleDesktopDialKey);
    _destinationFocus.dispose();
    _destinationController.dispose();
    super.dispose();
  }

  bool _handleDesktopDialKey(KeyEvent event) {
    if (!mounted || !supportsDesktopDialerKeyboard()) return false;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    if (ModalRoute.of(context)?.isCurrent != true) return false;
    if (_destinationFocus.hasFocus) return false;
    if (isInCallUiCall(ref.read(activeCallProvider).value)) return false;

    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed) {
      return false;
    }

    final character = dtmfCharacterFromKeyboard(event.character);
    if (character != null) {
      _insertDialText(character);
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.backspace) {
      _deleteBackward(1);
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      if (ref.read(dialerControllerProvider).isNotEmpty) {
        unawaited(_placeCall(context, ref));
      }
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final acceptsKeyboardInput = supportsDesktopDialerKeyboard();

    ref.listen<String>(dialerControllerProvider, (_, next) {
      _syncDestinationController(next);
    });
    _syncDestinationController(ref.read(dialerControllerProvider));

    final liveCall = ref.watch(activeCallProvider).value;
    if (isInCallUiCall(liveCall)) {
      return PageContent(
        maxWidth: 460,
        scrollable: false,
        padding: const EdgeInsets.fromLTRB(24, 18, 24, 24),
        child: InCallPanel(call: liveCall!),
      );
    }

    final registration =
        ref.watch(sipRegistrationStateProvider).value ??
        SipRegistrationState.initial();
    final session = ref.watch(sessionControllerProvider).value;
    final authUser = ref.watch(currentUserProvider).value;
    final settings = ref.watch(settingsControllerProvider);
    final dndEnabled = settings.dndEnabled;
    final scheme = Theme.of(context).colorScheme;
    final identity =
        [
              session?.sipConfig?.extension,
              authUser?.extension,
              authUser?.phoneNumber,
            ]
            .map((value) => value?.trim() ?? '')
            .firstWhere((value) => value.isNotEmpty, orElse: () => '');

    return PageContent(
      maxWidth: double.infinity,
      scrollable: false,
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = ResponsiveBreakpoints.isCompact(constraints.maxWidth);
          final availableHeight = constraints.maxHeight.isFinite
              ? constraints.maxHeight
              : MediaQuery.sizeOf(context).height * 0.76;
          final tight = availableHeight < 560;
          final keySpacing = tight ? 4.0 : (compact ? 6.0 : 8.0);
          final fieldVerticalPadding = tight ? 16.0 : 20.0;
          final keypadAspectRatio = tight
              ? (compact ? 1.55 : 1.85)
              : (compact ? 1.05 : 1.35);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _RegistrationHeader(
                registration: registration,
                identity: identity,
                dndEnabled: dndEnabled,
                dndScope: settings.dndScope,
                showActions: !acceptsKeyboardInput,
                onOpenSettings: () => context.push(RoutePaths.settings),
                onOpenHelp: () => showHelpSupportSheet(context),
                onOpenAccountDetail: () =>
                    _showAccountDetail(context, identity: identity),
              ),
              SizedBox(height: tight ? 8 : 12),
              Consumer(
                builder: (context, ref, _) {
                  final number = ref.watch(dialerControllerProvider);
                  return TextField(
                    controller: _destinationController,
                    focusNode: _destinationFocus,
                    autofocus: acceptsKeyboardInput,
                    readOnly: !acceptsKeyboardInput,
                    showCursor: true,
                    // Desktop text fields select all when they gain focus by
                    // default. The dial-pad focuses this read-only field after
                    // each key, so the next key would replace the prior digit.
                    selectAllOnFocus: false,
                    enableInteractiveSelection: true,
                    keyboardType: acceptsKeyboardInput
                        ? TextInputType.phone
                        : TextInputType.none,
                    textInputAction: acceptsKeyboardInput
                        ? TextInputAction.done
                        : null,
                    inputFormatters: acceptsKeyboardInput
                        ? [
                            FilteringTextInputFormatter.allow(
                              RegExp(r'[0-9*#+,;]'),
                            ),
                          ]
                        : const [],
                    enableSuggestions: false,
                    autocorrect: false,
                    textAlign: TextAlign.center,
                    style: AppTheme.numberStyle(
                      Theme.of(context).textTheme.titleLarge,
                      fontWeight: FontWeight.w600,
                    ),
                    cursorColor: scheme.primary,
                    contextMenuBuilder: (context, editableTextState) {
                      return _dialerNumberContextMenu(
                        editableTextState: editableTextState,
                        onPaste: _pasteDialText,
                      );
                    },
                    onChanged: acceptsKeyboardInput
                        ? (value) => ref
                              .read(dialerControllerProvider.notifier)
                              .setDestination(value)
                        : null,
                    onSubmitted: acceptsKeyboardInput && number.isNotEmpty
                        ? (_) => unawaited(_placeCall(context, ref))
                        : null,
                    decoration: InputDecoration(
                      hintText: 'Phone number',
                      filled: true,
                      fillColor: Theme.of(context).brightness == Brightness.dark
                          ? const Color(0xFF1A1C20)
                          : const Color(0xFFF3F4F6),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: fieldVerticalPadding,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(22),
                        borderSide: BorderSide.none,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(22),
                        borderSide: BorderSide(
                          color: scheme.outline.withValues(alpha: 0.35),
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(22),
                        borderSide: BorderSide(
                          color: scheme.outline.withValues(alpha: 0.35),
                        ),
                      ),
                      prefixIcon: number.isEmpty
                          ? null
                          : PopupMenuButton<_DialerMenuAction>(
                              tooltip: 'More',
                              color: scheme.surface,
                              surfaceTintColor: Colors.transparent,
                              icon: Icon(
                                AppIcons.moreVertical,
                                color: scheme.onSurfaceVariant,
                              ),
                              onSelected: (action) {
                                switch (action) {
                                  case _DialerMenuAction.pause:
                                    _insertDialText(',');
                                  case _DialerMenuAction.wait:
                                    _insertDialText(';');
                                }
                              },
                              itemBuilder: (context) => const [
                                PopupMenuItem(
                                  value: _DialerMenuAction.pause,
                                  child: Row(
                                    children: [
                                      Icon(AppIcons.hold, size: AppIconSize.sm),
                                      SizedBox(width: 12),
                                      Text('Add pause'),
                                    ],
                                  ),
                                ),
                                PopupMenuItem(
                                  value: _DialerMenuAction.wait,
                                  child: Row(
                                    children: [
                                      Icon(AppIcons.wait, size: AppIconSize.sm),
                                      SizedBox(width: 12),
                                      Text('Add wait'),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                      suffixIcon: _AcceleratingBackspaceButton(
                        enabled: number.isNotEmpty,
                        color: scheme.primary,
                        disabledColor: scheme.onSurfaceVariant.withValues(
                          alpha: 0.38,
                        ),
                        onDelete: _deleteBackward,
                        onClear: _clearDestination,
                      ),
                    ),
                  );
                },
              ),
              SizedBox(height: tight ? 12 : 18),
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: _DialPad(
                      aspectRatio: keypadAspectRatio,
                      keySpacing: keySpacing,
                      compact: tight,
                      onDigit: _insertDialText,
                      onBackspace: () => _deleteBackward(1),
                      onCallVoicemail: () async {
                        _setDestination('*97');
                        await _placeCall(context, ref);
                      },
                    ),
                  ),
                ),
              ),
              SizedBox(height: tight ? 12 : 18),
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: SizedBox(
                    width: double.infinity,
                    child: Consumer(
                      builder: (context, ref, _) {
                        final number = ref.watch(dialerControllerProvider);
                        return FilledButton.icon(
                          onPressed: number.isEmpty
                              ? null
                              : () async {
                                  await _placeCall(context, ref);
                                },
                          icon: const Icon(AppIcons.call, size: AppIconSize.md),
                          label: const Text('Call'),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _placeCall(BuildContext context, WidgetRef ref) async {
    try {
      final callId = await ref.read(dialerControllerProvider.notifier).call();
      if (callId != null && context.mounted) {
        // Connected calls stay on Dial; CallRouteListener keeps shell routing.
        context.go(RoutePaths.dialer);
      }
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      final message = error is AppException
          ? error.userMessage
          : 'Call could not start. Check registration diagnostics.';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  void _insertDialText(String value) {
    final selection = _destinationController.selection;
    final textLength = _destinationController.text.length;
    final start = selection.isValid ? selection.start : textLength;
    final end = selection.isValid ? selection.end : textLength;
    final cursor = ref
        .read(dialerControllerProvider.notifier)
        .replaceRange(start, end, value);
    _pendingCursor = cursor;
    _destinationFocus.requestFocus();
    _syncDestinationController(ref.read(dialerControllerProvider));
  }

  Future<void> _pasteDialText() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty || !mounted) {
      return;
    }
    _insertDialText(text);
  }

  void _deleteBackward(int count) {
    final selection = _destinationController.selection;
    final textLength = _destinationController.text.length;
    final cursor = selection.isValid ? selection.baseOffset : textLength;
    final selectionEnd = selection.isValid && !selection.isCollapsed
        ? selection.extentOffset
        : null;
    final nextCursor = ref
        .read(dialerControllerProvider.notifier)
        .deleteBackward(cursor, count: count, selectionEnd: selectionEnd);
    _pendingCursor = nextCursor;
    _destinationFocus.requestFocus();
    _syncDestinationController(ref.read(dialerControllerProvider));
  }

  void _clearDestination() {
    ref.read(dialerControllerProvider.notifier).clear();
    _pendingCursor = 0;
    _destinationFocus.requestFocus();
    _syncDestinationController('');
  }

  void _setDestination(String value) {
    ref.read(dialerControllerProvider.notifier).setDestination(value);
    _pendingCursor = value.length;
    _destinationFocus.requestFocus();
    _syncDestinationController(ref.read(dialerControllerProvider));
  }

  void _applyInitialDestination(String? value) {
    final destination = value?.trim() ?? '';
    if (destination.isEmpty) return;
    ref.read(dialerControllerProvider.notifier).setDestination(destination);
    _pendingCursor = ref.read(dialerControllerProvider).length;
  }

  Future<void> _showAccountDetail(
    BuildContext context, {
    required String identity,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (sheetContext) {
        return _AccountDetailSheet(identity: identity);
      },
    );
  }

  void _syncDestinationController(String value) {
    final pending = _pendingCursor;
    _pendingCursor = null;

    if (pending == null && _destinationController.text == value) {
      return;
    }

    final offset = (pending ?? value.length).clamp(0, value.length);
    if (_destinationController.text == value &&
        _destinationController.selection.isValid &&
        _destinationController.selection.isCollapsed &&
        _destinationController.selection.baseOffset == offset) {
      return;
    }

    _destinationController.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: offset),
    );
  }
}

class _AcceleratingBackspaceButton extends StatefulWidget {
  const _AcceleratingBackspaceButton({
    required this.enabled,
    required this.color,
    required this.disabledColor,
    required this.onDelete,
    required this.onClear,
  });

  final bool enabled;
  final Color color;
  final Color disabledColor;
  final ValueChanged<int> onDelete;
  final VoidCallback onClear;

  @override
  State<_AcceleratingBackspaceButton> createState() =>
      _AcceleratingBackspaceButtonState();
}

class _AcceleratingBackspaceButtonState
    extends State<_AcceleratingBackspaceButton> {
  Timer? _startTimer;
  Timer? _repeatTimer;
  final Stopwatch _heldFor = Stopwatch();

  @override
  void didUpdateWidget(covariant _AcceleratingBackspaceButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled) _stopDeleting();
  }

  @override
  void dispose() {
    _stopDeleting();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final iconColor = widget.enabled ? widget.color : widget.disabledColor;
    return Semantics(
      button: true,
      enabled: widget.enabled,
      label: 'Backspace. Hold to clear.',
      child: Tooltip(
        message: 'Backspace • hold to clear',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.enabled ? () => widget.onDelete(1) : null,
          onLongPressStart: widget.enabled ? (_) => _startDeleting() : null,
          onLongPressEnd: widget.enabled ? (_) => _stopDeleting() : null,
          onLongPressCancel: widget.enabled ? _stopDeleting : null,
          child: SizedBox(
            width: 48,
            height: 48,
            child: Center(child: Icon(AppIcons.delete, color: iconColor)),
          ),
        ),
      ),
    );
  }

  void _startDeleting() {
    _stopDeleting();
    _heldFor.start();
    widget.onDelete(1);
    _startTimer = Timer(const Duration(milliseconds: 320), () {
      _repeatTimer = Timer.periodic(const Duration(milliseconds: 90), (_) {
        final elapsed = _heldFor.elapsedMilliseconds;
        if (elapsed >= 1900) {
          widget.onClear();
          _stopDeleting();
        } else if (elapsed >= 1250) {
          widget.onDelete(4);
        } else if (elapsed >= 700) {
          widget.onDelete(2);
        } else {
          widget.onDelete(1);
        }
      });
    });
  }

  void _stopDeleting() {
    _startTimer?.cancel();
    _repeatTimer?.cancel();
    _startTimer = null;
    _repeatTimer = null;
    _heldFor
      ..stop()
      ..reset();
  }
}

enum _RegistrationPhase { offline, registering, registered }

const _registrationYellow = Color(0xFFF59E0B);
const _registrationGreen = Color(0xFF16835B);

class _RegistrationHeader extends StatelessWidget {
  const _RegistrationHeader({
    required this.registration,
    required this.identity,
    required this.dndEnabled,
    required this.dndScope,
    required this.showActions,
    required this.onOpenSettings,
    required this.onOpenHelp,
    required this.onOpenAccountDetail,
  });

  final SipRegistrationState registration;
  final String identity;
  final bool dndEnabled;
  final DndScope dndScope;
  final bool showActions;
  final VoidCallback onOpenSettings;
  final VoidCallback onOpenHelp;
  final VoidCallback onOpenAccountDetail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final phase = switch (registration.status) {
      SipRegistrationStatus.registered => _RegistrationPhase.registered,
      SipRegistrationStatus.configuring ||
      SipRegistrationStatus.registering => _RegistrationPhase.registering,
      _ => _RegistrationPhase.offline,
    };
    final color = switch (phase) {
      _RegistrationPhase.registered => _registrationGreen,
      _RegistrationPhase.registering => _registrationYellow,
      _RegistrationPhase.offline => theme.colorScheme.error,
    };

    return Row(
      children: [
        Flexible(
          child: Align(
            alignment: Alignment.centerLeft,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: _RegistrationCard(
                    phase: phase,
                    color: color,
                    identity: identity,
                    onTap: onOpenAccountDetail,
                  ),
                ),
                if (dndEnabled) ...[
                  const SizedBox(width: 10),
                  Text(
                    'DND',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: const Color(0xFFDC2626),
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.4,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    dndScope == DndScope.allDevices ? 'All' : 'Device',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (showActions) ...[
          const SizedBox(width: 10),
          IconButton(
            tooltip: 'Help & support',
            onPressed: onOpenHelp,
            icon: const Icon(AppIcons.help),
          ),
          IconButton.outlined(
            tooltip: 'Settings',
            onPressed: onOpenSettings,
            icon: const Icon(AppIcons.navSettings),
          ),
        ],
      ],
    );
  }
}

class _RegistrationCard extends StatelessWidget {
  const _RegistrationCard({
    required this.phase,
    required this.color,
    required this.identity,
    required this.onTap,
  });

  final _RegistrationPhase phase;
  final Color color;
  final String identity;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Avoid Container.alignment — with bounded max width it expands to fill
    // the row instead of wrapping the extension/number.
    final content = Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(12),
            border: phase == _RegistrationPhase.registering
                ? null
                : Border.all(color: color, width: 1.25),
          ),
          child: Center(
            widthFactor: 1,
            child: Text(
              identity,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTheme.numberStyle(theme.textTheme.labelLarge),
            ),
          ),
        ),
      ),
    );

    // Paint dots outside InkWell so the stroke isn't clipped by Material.
    if (phase != _RegistrationPhase.registering) {
      return content;
    }
    return CustomPaint(
      foregroundPainter: _DottedRoundedBorderPainter(color: color),
      child: content,
    );
  }
}

class _DottedRoundedBorderPainter extends CustomPainter {
  const _DottedRoundedBorderPainter({required this.color, this.radius = 12});

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    // Inset by half the stroke so dashes aren't clipped by parent bounds.
    const stroke = 1.4;
    const inset = stroke / 2;
    final corner = math.max(0.0, radius - inset);
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            inset,
            inset,
            size.width - stroke,
            size.height - stroke,
          ),
          Radius.circular(corner),
        ),
      );
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        canvas.drawPath(metric.extractPath(distance, distance + 3), paint);
        distance += 7;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DottedRoundedBorderPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.radius != radius;
}

class _AccountDetailSheet extends ConsumerWidget {
  const _AccountDetailSheet({required this.identity});

  final String identity;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final settings = ref.watch(settingsControllerProvider);
    final dndEnabled = settings.dndEnabled;
    final dndScope = settings.dndScope;
    final registration =
        ref.watch(sipRegistrationStateProvider).value ??
        SipRegistrationState.initial();
    final isRegistering =
        registration.status == SipRegistrationStatus.registering ||
        registration.status == SipRegistrationStatus.configuring;
    final statusLabel = switch (registration.status) {
      SipRegistrationStatus.registered => 'Registered',
      SipRegistrationStatus.registering => 'Registering',
      SipRegistrationStatus.configuring => 'Configuring',
      SipRegistrationStatus.failed => 'Failed',
      SipRegistrationStatus.unregistered => 'Unregistered',
      SipRegistrationStatus.uninitialized => 'Offline',
    };
    final statusColor = switch (registration.status) {
      SipRegistrationStatus.registered => const Color(0xFF22C55E),
      SipRegistrationStatus.registering ||
      SipRegistrationStatus.configuring => _registrationYellow,
      _ => const Color(0xFFF87171),
    };
    final displayIdentity = identity.trim().isEmpty ? '—' : identity.trim();
    final detailMessage = registration.message?.trim();

    final identityChip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: isRegistering
            ? null
            : Border.all(color: statusColor, width: 1.4),
      ),
      child: Text(
        displayIdentity,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppTheme.numberStyle(
          theme.textTheme.titleSmall,
          color: statusColor,
          fontWeight: FontWeight.w700,
        ),
      ),
    );

    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        4,
        20,
        20 + MediaQuery.paddingOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Account detail', style: theme.textTheme.titleLarge),
          const SizedBox(height: 18),
          Row(
            children: [
              Flexible(
                child: isRegistering
                    ? CustomPaint(
                        foregroundPainter: _DottedRoundedBorderPainter(
                          color: statusColor,
                          radius: 999,
                        ),
                        child: identityChip,
                      )
                    : identityChip,
              ),
              const SizedBox(width: 12),
              Text(
                statusLabel,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: statusColor,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          if (detailMessage != null && detailMessage.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              detailMessage,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 22),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Do not disturb',
                  style: theme.textTheme.titleMedium,
                ),
              ),
              Switch.adaptive(
                value: dndEnabled,
                activeThumbColor: Colors.white,
                activeTrackColor: theme.colorScheme.primary,
                inactiveThumbColor: Colors.white,
                inactiveTrackColor: theme.brightness == Brightness.dark
                    ? const Color(0xFF5C616A)
                    : const Color(0xFFB8BCC4),
                trackOutlineColor: WidgetStateProperty.resolveWith((states) {
                  if (states.contains(WidgetState.selected)) {
                    return Colors.transparent;
                  }
                  return theme.brightness == Brightness.dark
                      ? const Color(0xFF8A909A)
                      : const Color(0xFF8E949E);
                }),
                onChanged: (enabled) {
                  ref
                      .read(settingsControllerProvider.notifier)
                      .setDndEnabled(enabled: enabled);
                },
              ),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<DndScope>(
              segments: const [
                ButtonSegment(
                  value: DndScope.thisDevice,
                  icon: Icon(AppIcons.call),
                  label: Text('This device'),
                ),
                ButtonSegment(
                  value: DndScope.allDevices,
                  icon: Icon(AppIcons.cloud),
                  label: Text('All devices'),
                ),
              ],
              selected: {dndScope},
              showSelectedIcon: false,
              expandedInsets: EdgeInsets.zero,
              onSelectionChanged: (selection) {
                ref
                    .read(settingsControllerProvider.notifier)
                    .setDndScope(selection.single);
              },
            ),
          ),
          const SizedBox(height: 10),
          Text(
            dndScope == DndScope.thisDevice
                ? 'Only this device silently declines incoming calls. Your '
                      'other signed-in devices keep ringing.'
                : 'Turns on PBX DND for this extension, so incoming calls '
                      'stop on every signed-in device.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

enum _DialerMenuAction { pause, wait }

class _DialPad extends StatelessWidget {
  const _DialPad({
    required this.aspectRatio,
    required this.keySpacing,
    required this.compact,
    required this.onDigit,
    required this.onBackspace,
    required this.onCallVoicemail,
  });

  final double aspectRatio;
  final double keySpacing;
  final bool compact;
  final ValueChanged<String> onDigit;
  final VoidCallback onBackspace;
  final Future<void> Function() onCallVoicemail;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        var effectiveAspectRatio = aspectRatio;
        if (constraints.maxWidth.isFinite && constraints.maxHeight.isFinite) {
          const columns = 3;
          const rows = 4;
          final cellWidth =
              (constraints.maxWidth - keySpacing * (columns - 1)) / columns;
          final cellHeight =
              (constraints.maxHeight - keySpacing * (rows - 1)) / rows;
          if (cellWidth > 0 && cellHeight > 0) {
            final ratioRequiredToFit = cellWidth / cellHeight;
            if (ratioRequiredToFit > effectiveAspectRatio) {
              effectiveAspectRatio = ratioRequiredToFit;
            }
          }
        }

        return GridView.builder(
          primary: false,
          padding: EdgeInsets.zero,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            childAspectRatio: effectiveAspectRatio,
            crossAxisSpacing: keySpacing,
            mainAxisSpacing: keySpacing,
          ),
          itemCount: DialerScreen._keys.length,
          itemBuilder: (context, index) {
            final key = DialerScreen._keys[index];
            return _DialButton(
              value: key.value,
              letters: key.letters,
              icon: key.icon,
              compact: compact,
              onPressed: () => onDigit(key.value),
              onLongPress: switch (key.value) {
                '0' => () => onDigit('+'),
                '1' => () {
                  onCallVoicemail();
                },
                _ => null,
              },
              onUndoDigit: key.value == '0' || key.value == '1'
                  ? onBackspace
                  : null,
            );
          },
        );
      },
    );
  }
}

class _DialKey {
  const _DialKey(this.value, this.letters, {this.icon});

  final String value;
  final String letters;
  final IconData? icon;
}

class _DialButton extends StatefulWidget {
  const _DialButton({
    required this.value,
    required this.letters,
    required this.compact,
    required this.onPressed,
    this.icon,
    this.onLongPress,
    this.onUndoDigit,
  });

  final String value;
  final String letters;
  final IconData? icon;
  final bool compact;
  final VoidCallback onPressed;
  final VoidCallback? onLongPress;
  final VoidCallback? onUndoDigit;

  @override
  State<_DialButton> createState() => _DialButtonState();
}

class _DialButtonState extends State<_DialButton> {
  var _digitInserted = false;

  void _handleTapDown() {
    _digitInserted = true;
    widget.onPressed();
  }

  void _handleLongPress() {
    final longPress = widget.onLongPress;
    if (longPress == null) return;
    if (_digitInserted) {
      widget.onUndoDigit?.call();
    }
    _digitInserted = false;
    longPress();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subtitleColor = theme.colorScheme.onSurfaceVariant;
    final outline = theme.colorScheme.outline;

    // Register on press-down so fast taps are not lost if the finger lifts
    // slightly off-key or a parent rebuild interrupts the gesture.
    return Material(
      color: theme.colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: BorderSide(color: outline.withValues(alpha: 0.45)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTapDown: (_) => _handleTapDown(),
        onLongPress: widget.onLongPress == null ? null : _handleLongPress,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              widget.value,
              style: AppTheme.numberStyle(
                widget.compact
                    ? theme.textTheme.headlineSmall
                    : theme.textTheme.headlineMedium,
                fontWeight: FontWeight.w700,
              ),
            ),
            SizedBox(
              height: widget.compact ? 20 : 24,
              child: widget.icon != null
                  ? Icon(
                      widget.icon,
                      size: widget.compact ? 14 : 16,
                      color: theme.colorScheme.primary,
                    )
                  : Text(
                      widget.letters,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: subtitleColor,
                        fontWeight: FontWeight.w700,
                        fontSize: widget.letters.length <= 1
                            ? (widget.compact ? 22 : 26)
                            : (widget.compact ? 13 : 14),
                        letterSpacing: widget.letters.length <= 1 ? 0 : 0.4,
                        height: 1,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

Widget _dialerNumberContextMenu({
  required EditableTextState editableTextState,
  required Future<void> Function() onPaste,
}) {
  final value = editableTextState.textEditingValue;
  final selection = value.selection;
  final hasSelection = selection.isValid && !selection.isCollapsed;
  final hasText = value.text.isNotEmpty;
  final buttonItems = <ContextMenuButtonItem>[
    if (hasSelection)
      ContextMenuButtonItem(
        label: 'Copy',
        onPressed: () {
          editableTextState.copySelection(SelectionChangedCause.toolbar);
          editableTextState.hideToolbar();
        },
      ),
    ContextMenuButtonItem(
      label: 'Paste',
      onPressed: () {
        editableTextState.hideToolbar();
        unawaited(onPaste());
      },
    ),
    if (hasText)
      ContextMenuButtonItem(
        label: 'Select all',
        onPressed: () {
          editableTextState.selectAll(SelectionChangedCause.toolbar);
        },
      ),
  ];

  return AdaptiveTextSelectionToolbar.buttonItems(
    anchors: editableTextState.contextMenuAnchors,
    buttonItems: buttonItems,
  );
}
