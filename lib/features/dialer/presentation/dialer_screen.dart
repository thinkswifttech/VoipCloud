import '../../accounts/presentation/line_tone.dart';
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
import '../../../shared/widgets/app_modal_bottom_sheet.dart';
import '../../../shared/widgets/help_support_sheet.dart';
import '../../../shared/widgets/page_content.dart';
import '../../../shared/widgets/responsive.dart';
import '../../accounts/domain/account_line.dart';
import '../../auth/presentation/auth_providers.dart';
import '../../calls/presentation/call_session_providers.dart';
import '../../calls/presentation/call_waiting_presentation.dart';
import '../../calls/presentation/in_call_panel.dart';
import '../../session/presentation/session_controller.dart';
import '../../settings/presentation/settings_controller.dart';
import '../../settings/presentation/dnd_settings_section.dart';
import '../../sip/domain/sip_registration_state.dart';
import '../../sip/presentation/calling_status_text.dart';
import '../../accounts/presentation/accounts_controller.dart';
import '../../accounts/presentation/line_widgets.dart';
import '../../accounts/domain/line_resolver.dart';
import 'dialer_controller.dart';
import 'dialer_line.dart';
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
  int _initialDestinationRevision = 0;

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
    if (ref.read(displayedInCallProvider) != null) return false;

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

    final liveCall = ref.watch(displayedInCallProvider);
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
    final hasSecond = ref.watch(hasSecondaryAccountProvider);
    final lines = ref.watch(accountLinesProvider);
    final secondRegistration =
        ref.watch(secondaryRegistrationStateProvider).value ??
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
                primaryDotColor: hasSecond ? lines.first.colorValue : null,
                primaryDnd:
                    settings.localDndEnabled || settings.pbxDnd.enabled == true,
                second: hasSecond && lines.length > 1
                    ? _SecondLineChip(
                        registration: secondRegistration,
                        identity: lines.last.config?.extension.trim() ?? '',
                        colorValue: lines.last.colorValue,
                        dnd:
                            settings.localDndEnabled ||
                            settings.secondaryPbxDnd.enabled == true,
                      )
                    : null,
                onOpenSecondDetail: () => _showAccountDetail(
                  context,
                  identity: lines.last.config?.extension.trim() ?? '',
                ),
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
                        final button = FilledButton.icon(
                          onPressed: number.isEmpty
                              ? null
                              : () async {
                                  await _placeCall(context, ref);
                                },
                          icon: const Icon(AppIcons.call, size: AppIconSize.md),
                          label: const Text('Call'),
                        );
                        if (!ref.watch(hasSecondaryAccountProvider)) {
                          return button;
                        }
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // Kept in the layout (just hidden) so the Call
                            // button does not jump when typing starts.
                            Visibility(
                              visible: number.isNotEmpty,
                              maintainSize: true,
                              maintainAnimation: true,
                              maintainState: true,
                              child: const _CallingFromSelector(),
                            ),
                            const SizedBox(height: 8),
                            button,
                          ],
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
      final line = ref.read(hasSecondaryAccountProvider)
          ? await chooseLineForCall(context, ref)
          : AccountLine.primary;
      // Dismissing the "which account?" question cancels the call.
      if (line == null) return;
      final callId = await ref
          .read(dialerControllerProvider.notifier)
          .call(line: line);
      ref.read(dialerLineHintProvider.notifier).clear();
      ref.read(dialerLineOverrideProvider.notifier).clear();
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
          : "Couldn't start the call. Please try again.";
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
    final destination = normalizeDialDestination(value?.trim() ?? '');
    if (destination.isEmpty) return;

    final revision = ++_initialDestinationRevision;
    final current = ref.read(dialerControllerProvider);
    if (current == destination) {
      _pendingCursor = destination.length;
      _syncDestinationController(destination);
      return;
    }

    // A route query can update this existing screen through didUpdateWidget.
    // Riverpod correctly rejects provider mutations during that build phase,
    // so defer a genuinely new destination until the frame has completed.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || revision != _initialDestinationRevision) return;
      ref.read(dialerControllerProvider.notifier).setDestination(destination);
      _pendingCursor = destination.length;
      _syncDestinationController(destination);
    });
  }

  Future<void> _showAccountDetail(
    BuildContext context, {
    required String identity,
  }) {
    return showAppModalBottomSheet<void>(
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

/// The second account's small connection chip next to the primary one.
class _SecondLineChip {
  const _SecondLineChip({
    required this.registration,
    required this.identity,
    required this.colorValue,
    required this.dnd,
  });

  final SipRegistrationState registration;
  final String identity;
  final int colorValue;
  final bool dnd;
}

class _RegistrationHeader extends StatelessWidget {
  const _RegistrationHeader({
    required this.registration,
    required this.identity,
    this.primaryDotColor,
    this.primaryDnd = false,
    this.second,
    this.onOpenSecondDetail,
    required this.dndEnabled,
    required this.dndScope,
    required this.showActions,
    required this.onOpenSettings,
    required this.onOpenHelp,
    required this.onOpenAccountDetail,
  });

  final SipRegistrationState registration;
  final String identity;
  final int? primaryDotColor;
  final bool primaryDnd;
  final _SecondLineChip? second;
  final VoidCallback? onOpenSecondDetail;
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
                  child: second == null
                      ? _RegistrationCard(
                          phase: phase,
                          color: color,
                          identity: identity,
                          onTap: onOpenAccountDetail,
                        )
                      : _LinesPill(
                          first: _PillSegment(
                            identity: identity,
                            colorValue: primaryDotColor ?? 0xFF2B5FD9,
                            status: registration.status,
                            dnd: primaryDnd,
                            onTap: onOpenAccountDetail,
                          ),
                          second: _PillSegment(
                            identity: second!.identity,
                            colorValue: second!.colorValue,
                            status: second!.registration.status,
                            dnd: second!.dnd,
                            onTap: onOpenSecondDetail ?? () {},
                          ),
                        ),
                ),
                // With two accounts each chip carries its own DND mark.
                if (dndEnabled && second == null) ...[
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

class _PillSegment {
  const _PillSegment({
    required this.identity,
    required this.colorValue,
    required this.status,
    required this.dnd,
    required this.onTap,
  });

  final String identity;
  final int colorValue;
  final SipRegistrationStatus status;
  final bool dnd;
  final VoidCallback onTap;
}

/// Both accounts as one compact control: each half shows the account's
/// colour mark and extension. A healthy account shows nothing else; an
/// account that is connecting or offline gets a warning mark, and one with
/// do-not-disturb on gets a bell-off mark. Tap a half for details.
class _LinesPill extends StatelessWidget {
  const _LinesPill({required this.first, required this.second});

  final _PillSegment first;
  final _PillSegment second;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: 44,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(child: _PillHalf(segment: first)),
          VerticalDivider(
            width: 1,
            thickness: 1,
            indent: 10,
            endIndent: 10,
            color: theme.colorScheme.outlineVariant,
          ),
          Flexible(child: _PillHalf(segment: second)),
        ],
      ),
    );
  }
}

class _PillHalf extends StatelessWidget {
  const _PillHalf({required this.segment});

  final _PillSegment segment;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tone = LineTone.of(context, segment.colorValue);
    final (statusIcon, statusColor, statusText) = switch (segment.status) {
      SipRegistrationStatus.registered => (null, null, ''),
      SipRegistrationStatus.configuring || SipRegistrationStatus.registering =>
        (AppIcons.refresh, _registrationYellow, ', connecting'),
      _ => (AppIcons.warning, theme.colorScheme.error, ', not connected'),
    };
    return Semantics(
      button: true,
      label:
          'Account ${segment.identity}$statusText'
          '${segment.dnd ? ', do not disturb on' : ''}',
      child: InkWell(
        onTap: segment.onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              LineDot(colorValue: segment.colorValue, size: 8),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  segment.identity,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTheme.numberStyle(
                    theme.textTheme.labelLarge,
                    color: tone.onSoft,
                  ),
                ),
              ),
              if (statusIcon != null) ...[
                const SizedBox(width: 6),
                Icon(statusIcon, size: 15, color: statusColor),
              ],
              if (segment.dnd) ...[
                const SizedBox(width: 6),
                const Icon(
                  AppIcons.bellOff,
                  size: 15,
                  color: Color(0xFFDC2626),
                ),
              ],
            ],
          ),
        ),
      ),
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

/// One sheet for both accounts: each account's connection is listed, and
/// do-not-disturb sits below for the whole phone.
class _AccountDetailSheet extends ConsumerWidget {
  const _AccountDetailSheet({required this.identity});

  final String identity;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final settings = ref.watch(settingsControllerProvider);
    final dndScope = settings.dndScope;
    final lines = ref.watch(accountLinesProvider);
    final hasSecond =
        ref.watch(hasSecondaryAccountProvider) && lines.length > 1;
    String extensionOf(AccountLine target) =>
        lines
            .where((info) => info.line == target)
            .firstOrNull
            ?.config
            ?.extension
            .trim() ??
        '';
    int colorOf(AccountLine target) =>
        lines.where((info) => info.line == target).firstOrNull?.colorValue ??
        0xFF2B5FD9;

    Widget statusRow(AccountLine line) {
      final registration =
          (line == AccountLine.secondary
              ? ref.watch(secondaryRegistrationStateProvider).value
              : ref.watch(sipRegistrationStateProvider).value) ??
          SipRegistrationState.initial();
      final isRegistering =
          registration.status == SipRegistrationStatus.registering ||
          registration.status == SipRegistrationStatus.configuring;
      final statusColor = switch (registration.status) {
        SipRegistrationStatus.registered => const Color(0xFF22C55E),
        SipRegistrationStatus.registering ||
        SipRegistrationStatus.configuring => _registrationYellow,
        _ => const Color(0xFFF87171),
      };
      final extension = line == AccountLine.secondary
          ? extensionOf(line)
          : (extensionOf(line).isNotEmpty ? extensionOf(line) : identity);
      final detailMessage = CallingStatusText.dialerDetail(registration.status);
      final identityChip = Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          border: isRegistering
              ? null
              : Border.all(color: statusColor, width: 1.4),
        ),
        child: Text(
          extension.trim().isEmpty ? '—' : extension.trim(),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppTheme.numberStyle(
            theme.textTheme.titleSmall,
            color: statusColor,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (hasSecond) ...[
                LineDot(colorValue: colorOf(line), size: 10),
                const SizedBox(width: 10),
              ],
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
                CallingStatusText.label(
                  registration.status,
                  reconnecting: registration.reconnecting,
                ),
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
        ],
      );
    }

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
          statusRow(AccountLine.primary),
          if (hasSecond) ...[
            const SizedBox(height: 12),
            statusRow(AccountLine.secondary),
          ],
          const SizedBox(height: 22),
          DndSettingsSection(
            enabled: settings.selectedDndEnabled,
            pbxState: settings.pbxDnd,
            scope: dndScope,
            accountSwitches: hasSecond
                ? [
                    for (final target in AccountLine.values)
                      DndAccountSwitch(
                        extension: extensionOf(target),
                        colorValue: colorOf(target),
                        pbxState: target == AccountLine.secondary
                            ? settings.secondaryPbxDnd
                            : settings.pbxDnd,
                        onChanged: (enabled) => ref
                            .read(settingsControllerProvider.notifier)
                            .setPbxDndEnabled(target, enabled: enabled),
                      ),
                  ]
                : const [],
            onEnabledChanged: (enabled) => ref
                .read(settingsControllerProvider.notifier)
                .setDndEnabled(enabled: enabled),
            onScopeChanged: (scope) => ref
                .read(settingsControllerProvider.notifier)
                .setDndScope(scope),
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

/// "Call from" with both accounts as one segmented control: the account the
/// Call button will use is selected (one tap switches it), with a short
/// reason under it. Hidden, space kept, until a number is typed.
class _CallingFromSelector extends ConsumerWidget {
  const _CallingFromSelector();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final choice = ref.watch(dialerLineChoiceProvider);
    final lines = ref.watch(accountLinesProvider);
    final destination = ref.watch(dialerControllerProvider);
    final override = ref.watch(dialerLineOverrideProvider);
    final chosenByHand =
        override != null &&
        override.destination == normalizeDialDestination(destination);
    final reason = choice.line == null
        ? 'Choose which account to call from'
        : chosenByHand
        ? 'You chose this account'
        : switch (choice.reason) {
            LineReason.context => 'Same account as the entry you tapped',
            LineReason.numberHistory =>
              'Used for your last call with this number',
            LineReason.defaultSetting => 'Your default account',
            _ => '',
          };
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LineSegmented(
          lines: lines,
          selected: choice.line,
          onSelected: (line) {
            if (line == null) return;
            ref
                .read(dialerLineOverrideProvider.notifier)
                .set(destination, line);
          },
        ),
        const SizedBox(height: 4),
        Text(
          reason.isEmpty ? ' ' : reason,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
