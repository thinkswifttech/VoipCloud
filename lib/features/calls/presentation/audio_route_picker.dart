import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/audio_output_route.dart';
import '../application/reset_audio_volumes.dart';
import '../domain/audio_volume_levels.dart';
import '../../session/presentation/session_controller.dart';
import '../../../shared/icons/app_icons.dart';
import '../../../shared/widgets/app_modal_bottom_sheet.dart';
import 'desktop_audio_test_dialog.dart';

Future<void> showAudioRoutePicker({
  required BuildContext context,
  required WidgetRef ref,
  required AudioOutputRoute selectedRoute,
  bool choosingDefaults = false,
}) async {
  final service = ref.read(sipServiceProvider);
  final messenger = ScaffoldMessenger.of(context);

  // Don't block the sheet on the Bluetooth permission prompt.
  if ((!choosingDefaults && Platform.isAndroid) ||
      Platform.isWindows ||
      Platform.isMacOS) {
    unawaited(service.ensureBluetoothPermission());
  }

  if (!context.mounted) {
    return;
  }

  await showAppModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) {
      return _AudioRoutePickerSheet(
        initialRoute: selectedRoute,
        messenger: messenger,
        choosingDefaults: choosingDefaults,
      );
    },
  );
}

class _AudioRoutePickerSheet extends ConsumerStatefulWidget {
  const _AudioRoutePickerSheet({
    required this.initialRoute,
    required this.messenger,
    required this.choosingDefaults,
  });

  final AudioOutputRoute initialRoute;
  final ScaffoldMessengerState messenger;
  final bool choosingDefaults;

  @override
  ConsumerState<_AudioRoutePickerSheet> createState() =>
      _AudioRoutePickerSheetState();
}

class _AudioRoutePickerSheetState
    extends ConsumerState<_AudioRoutePickerSheet> {
  List<AudioOutputRouteOption>? _options;
  var _loading = true;
  var _reloadInFlight = false;
  String? _selectingDeviceKey;
  Timer? _refreshTimer;
  Timer? _volumeCommitTimer;
  AudioVolumeLevels? _volumeLevels;
  bool _volumeLoadFailed = false;
  bool _resettingVolumes = false;
  bool _previewingWaitingAlert = false;
  Future<void> _volumeWrites = Future<void>.value();

  bool get _showDeviceList =>
      !(Platform.isAndroid || Platform.isIOS) ||
      (!widget.choosingDefaults && !Platform.isIOS);

  @override
  void initState() {
    super.initState();
    if (_showDeviceList) unawaited(_reloadRoutes());
    if (widget.choosingDefaults || !(Platform.isAndroid || Platform.isIOS)) {
      unawaited(_loadVolumeLevels());
    }
    // Refresh while open so Bluetooth connect/disconnect appears live.
    if (_showDeviceList) {
      _refreshTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        unawaited(_reloadRoutes(silent: true));
      });
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _volumeCommitTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadVolumeLevels() async {
    try {
      final levels = await ref.read(sipServiceProvider).getAudioVolumeLevels();
      if (!mounted) return;
      setState(() {
        _volumeLevels = levels;
        _volumeLoadFailed = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _volumeLoadFailed = true);
    }
  }

  Future<void> _reloadRoutes({bool silent = false}) async {
    if (_reloadInFlight || _selectingDeviceKey != null) return;
    _reloadInFlight = true;
    try {
      final service = ref.read(sipServiceProvider);
      final options = await service.getAudioRoutes();
      if (!mounted) {
        return;
      }
      setState(() {
        _options = options;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || silent) {
        return;
      }
      setState(() => _loading = false);
      widget.messenger.showSnackBar(
        const SnackBar(content: Text('Unable to load audio outputs.')),
      );
      // Settings volume controls do not depend on route discovery. Keep the
      // sheet open so a temporary Bluetooth/audio-route failure cannot hide
      // the mobile safety controls.
    } finally {
      _reloadInFlight = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final liveCall = ref.watch(activeCallProvider).value;
    final selectedRoute = liveCall?.audioRoute ?? widget.initialRoute;
    final liveEndpoints = liveCall?.availableAudioEndpoints ?? const [];
    final allOptions = liveEndpoints.isNotEmpty ? liveEndpoints : _options;
    final outputs = allOptions == null
        ? null
        : _normalizedRoutes(
            allOptions
                .where(
                  (option) => option.direction == AudioDeviceDirection.output,
                )
                .toList(growable: false),
          );
    final inputs =
        allOptions
            ?.where((option) => option.direction == AudioDeviceDirection.input)
            .toList(growable: false) ??
        const <AudioOutputRouteOption>[];
    final hasSeparateDevices = inputs.isNotEmpty;

    final availableHeight = MediaQuery.sizeOf(context).height;

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: availableHeight * 0.9),
        child: Scrollbar(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  widget.choosingDefaults &&
                          (Platform.isAndroid || Platform.isIOS)
                      ? 'Audio settings'
                      : 'Audio',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  widget.choosingDefaults &&
                          (Platform.isAndroid || Platform.isIOS)
                      ? 'Adjust call-waiting alerts. '
                            'Use your phone’s volume controls for calls and incoming ringing.'
                      : hasSeparateDevices
                      ? widget.choosingDefaults
                            ? 'Choose the speaker and microphone VoipCloud uses.'
                            : 'Choose a speaker and microphone for this call.'
                      : 'Choose where call audio plays.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                if (Platform.isIOS && !widget.choosingDefaults)
                  const _IosSystemAudioOutput(),
                if (_showDeviceList && _loading && outputs == null)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (_showDeviceList && outputs != null) ...[
                  if (hasSeparateDevices)
                    const _AudioDeviceSectionLabel('Speaker'),
                  for (final option in outputs)
                    ListTile(
                      enabled: option.available && _selectingDeviceKey == null,
                      leading: Icon(_iconForRoute(option.route)),
                      title: Text(option.label),
                      trailing: _selectingDeviceKey == _deviceKey(option)
                          ? const SizedBox.square(
                              dimension: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : _isSelected(option, outputs, selectedRoute)
                          ? Icon(
                              Icons.check_rounded,
                              color: Theme.of(context).colorScheme.primary,
                            )
                          : null,
                      selected: _isSelected(option, outputs, selectedRoute),
                      onTap: !option.available || _selectingDeviceKey != null
                          ? null
                          : () => unawaited(_selectDevice(option)),
                    ),
                  if (hasSeparateDevices) ...[
                    const Divider(),
                    const _AudioDeviceSectionLabel('Microphone'),
                    for (final option in inputs)
                      ListTile(
                        enabled:
                            option.available && _selectingDeviceKey == null,
                        leading: const Icon(Icons.mic_rounded),
                        title: Text(option.label),
                        trailing: _selectingDeviceKey == _deviceKey(option)
                            ? const SizedBox.square(
                                dimension: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : option.selected
                            ? Icon(
                                Icons.check_rounded,
                                color: Theme.of(context).colorScheme.primary,
                              )
                            : null,
                        selected: option.selected,
                        onTap: !option.available || _selectingDeviceKey != null
                            ? null
                            : () => unawaited(_selectDevice(option)),
                      ),
                    if (widget.choosingDefaults) ...[
                      const Divider(),
                      if (Platform.isWindows || Platform.isMacOS) ...[
                        const _AudioDeviceSectionLabel('Volume'),
                        if (_volumeLevels case final levels?)
                          _DesktopVolumeControls(
                            levels: levels,
                            enabled: !_resettingVolumes,
                            onChanged: _changeVolume,
                            onChangeEnd: _commitVolume,
                          )
                        else if (_volumeLoadFailed)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    'Unable to load volume controls.',
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.onSurfaceVariant,
                                        ),
                                  ),
                                ),
                                TextButton(
                                  onPressed: () {
                                    setState(() => _volumeLoadFailed = false);
                                    unawaited(_loadVolumeLevels());
                                  },
                                  child: const Text('Retry'),
                                ),
                              ],
                            ),
                          )
                        else
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 20),
                            child: Center(
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                        const Divider(),
                      ],
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.graphic_eq_rounded),
                          label: const Text('Test audio'),
                          onPressed: _selectingDeviceKey != null
                              ? null
                              : () => showDesktopAudioTestDialog(
                                  context: context,
                                ),
                        ),
                      ),
                    ],
                  ],
                ],
                if (widget.choosingDefaults &&
                    (Platform.isAndroid || Platform.isIOS)) ...[
                  const Divider(),
                  const _AudioDeviceSectionLabel('Volume'),
                  const _AudioSafetyNotice(),
                  if (_volumeLevels case final levels?)
                    _DesktopVolumeControls(
                      levels: levels,
                      enabled: !_resettingVolumes,
                      onChanged: _changeVolume,
                      onChangeEnd: _commitVolume,
                    )
                  else if (_volumeLoadFailed)
                    ListTile(
                      title: const Text('Unable to load volume controls.'),
                      trailing: TextButton(
                        onPressed: _loadVolumeLevels,
                        child: const Text('Retry'),
                      ),
                    )
                  else
                    const Padding(
                      padding: EdgeInsets.all(20),
                      child: Center(
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                ],
                if (widget.choosingDefaults && _volumeLevels != null) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.volume_up_outlined),
                      label: const Text('Preview call waiting alert'),
                      onPressed:
                          liveCall != null ||
                              _resettingVolumes ||
                              _previewingWaitingAlert
                          ? null
                          : () => unawaited(_previewWaitingAlert()),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      liveCall != null
                          ? 'Finish all calls to preview the alert.'
                          : 'One short beep at the selected level. Device volume and audio output also affect loudness.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
                if (widget.choosingDefaults)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                    child: OutlinedButton.icon(
                      onPressed: _volumeLevels == null || _resettingVolumes
                          ? null
                          : () => unawaited(_resetVolumeDefaults()),
                      icon: _resettingVolumes
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.restore_rounded),
                      label: Text(
                        _resettingVolumes ? 'Resetting…' : 'Reset to defaults',
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _selectDevice(AudioOutputRouteOption option) async {
    final service = ref.read(sipServiceProvider);
    if (_selectingDeviceKey != null) return;
    setState(() {
      _selectingDeviceKey = _deviceKey(option);
    });
    try {
      if (option.direction == AudioDeviceDirection.input) {
        final endpointId = option.endpointId;
        if (endpointId == null) return;
        await service.setAudioInputDevice(endpointId);
      } else {
        await service.setAudioRoute(
          option.route,
          endpointId: option.endpointId,
        );
      }
      if (!mounted) return;
      setState(() => _selectingDeviceKey = null);
      await _reloadRoutes(silent: true);
    } catch (_) {
      if (!mounted) return;
      setState(() => _selectingDeviceKey = null);
      widget.messenger.showSnackBar(
        const SnackBar(
          content: Text('That audio device is no longer available.'),
        ),
      );
    }
  }

  void _changeVolume(AudioVolumeKind kind, double value) {
    if (_resettingVolumes) return;
    final current = _volumeLevels;
    if (current == null) return;
    final level = value.round().clamp(0, 100);
    setState(() {
      _volumeLevels = switch (kind) {
        AudioVolumeKind.microphone => current.copyWith(microphone: level),
        AudioVolumeKind.callAudio => current.copyWith(callAudio: level),
        AudioVolumeKind.ringtone => current.copyWith(ringtone: level),
        AudioVolumeKind.ringback => current.copyWith(ringback: level),
        AudioVolumeKind.callWaiting => current.copyWith(callWaiting: level),
      };
    });
    _volumeCommitTimer?.cancel();
    _volumeCommitTimer = Timer(
      const Duration(milliseconds: 100),
      () => unawaited(_saveVolume(kind, level)),
    );
  }

  void _commitVolume(AudioVolumeKind kind, double value) {
    if (_resettingVolumes) return;
    _volumeCommitTimer?.cancel();
    unawaited(_saveVolume(kind, value.round().clamp(0, 100)));
  }

  Future<void> _saveVolume(AudioVolumeKind kind, int level) {
    // Serialize slider writes so an older request cannot overwrite a reset.
    final service = ref.read(sipServiceProvider);
    _volumeWrites = _volumeWrites.then((_) async {
      try {
        await service.setAudioVolume(kind, level);
      } catch (_) {
        if (!mounted) return;
        widget.messenger.showSnackBar(
          const SnackBar(content: Text('Unable to save that volume level.')),
        );
        await _loadVolumeLevels();
      }
    });
    return _volumeWrites;
  }

  Future<void> _resetVolumeDefaults() async {
    if (_resettingVolumes) return;
    _volumeCommitTimer?.cancel();
    final service = ref.read(sipServiceProvider);
    setState(() => _resettingVolumes = true);
    try {
      await _volumeWrites;
      await resetAudioVolumes(
        save: service.setAudioVolume,
        mobileControlsOnly: Platform.isAndroid || Platform.isIOS,
      );
      if (mounted) {
        widget.messenger.showSnackBar(
          const SnackBar(content: Text('Audio levels reset to defaults.')),
        );
      }
    } catch (_) {
      if (mounted) {
        widget.messenger.showSnackBar(
          const SnackBar(
            content: Text(
              'Some audio levels could not be reset. Please try again.',
            ),
          ),
        );
      }
    } finally {
      // Read the actual persisted levels, including a partially failed reset.
      if (mounted) {
        await _loadVolumeLevels();
        if (mounted) setState(() => _resettingVolumes = false);
      }
    }
  }

  Future<void> _previewWaitingAlert() async {
    if (_previewingWaitingAlert || _volumeLevels == null) return;
    _volumeCommitTimer?.cancel();
    final level = _volumeLevels!.callWaiting;
    setState(() => _previewingWaitingAlert = true);
    try {
      // Serialize with slider writes; preview the displayed value, without
      // relying on an older persisted value or changing the system mixer.
      await _volumeWrites;
      final service = ref.read(sipServiceProvider);
      await service.setAudioVolume(AudioVolumeKind.callWaiting, level);
      await service.previewCallWaitingAlert(level);
      await Future<void>.delayed(const Duration(seconds: 1));
    } catch (_) {
      if (mounted) {
        widget.messenger.showSnackBar(
          const SnackBar(
            content: Text(
              'Unable to preview the alert. Finish all calls and try again.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _previewingWaitingAlert = false);
    }
  }
}

/// Apple owns the route list; our sheet owns the adjacent volume controls.
/// The supported native view remains the actual touch target.
class _IosSystemAudioOutput extends StatelessWidget {
  const _IosSystemAudioOutput();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          const Expanded(
            child: ListTile(
              title: Text('Audio output'),
              subtitle: Text('Change speaker, headphones, or Bluetooth'),
            ),
          ),
          SizedBox.square(
            dimension: 48,
            child: Stack(
              fit: StackFit.expand,
              children: [
                IgnorePointer(
                  child: IconButton.outlined(
                    tooltip: 'Change audio output',
                    onPressed: () {},
                    icon: const Icon(Icons.speaker_rounded),
                  ),
                ),
                const UiKitView(viewType: 'voipcloud/audio_route_picker'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DesktopVolumeControls extends StatelessWidget {
  const _DesktopVolumeControls({
    required this.levels,
    required this.onChanged,
    required this.onChangeEnd,
    this.enabled = true,
  });

  final AudioVolumeLevels levels;
  final bool enabled;
  final void Function(AudioVolumeKind kind, double value) onChanged;
  final void Function(AudioVolumeKind kind, double value) onChangeEnd;

  @override
  Widget build(BuildContext context) {
    return AbsorbPointer(
      absorbing: !enabled,
      child: Column(
        children: [
          if (!(Platform.isAndroid || Platform.isIOS)) ...[
            _VolumeSlider(
              icon: Icons.mic_rounded,
              label: 'Microphone',
              description: 'How loudly other people hear you',
              value: levels.microphone,
              onChanged: (value) =>
                  onChanged(AudioVolumeKind.microphone, value),
              onChangeEnd: (value) =>
                  onChangeEnd(AudioVolumeKind.microphone, value),
            ),
            _VolumeSlider(
              icon: Icons.headphones_rounded,
              label: 'Call audio',
              description: 'Speaker or headset volume during calls',
              value: levels.callAudio,
              onChanged: (value) => onChanged(AudioVolumeKind.callAudio, value),
              onChangeEnd: (value) =>
                  onChangeEnd(AudioVolumeKind.callAudio, value),
            ),
          ],
          if (!(Platform.isAndroid || Platform.isIOS))
            _VolumeSlider(
              icon: Icons.notifications_active_rounded,
              label: 'Incoming call ringtone',
              description: 'Ringing volume before you answer',
              value: levels.ringtone,
              onChanged: (value) => onChanged(AudioVolumeKind.ringtone, value),
              onChangeEnd: (value) =>
                  onChangeEnd(AudioVolumeKind.ringtone, value),
            ),
          if (!(Platform.isAndroid || Platform.isIOS))
            _VolumeSlider(
              icon: Icons.call_outlined,
              label: 'Outgoing ringback',
              description: 'Ringing you hear while the other phone rings',
              value: levels.ringback,
              onChanged: (value) => onChanged(AudioVolumeKind.ringback, value),
              onChangeEnd: (value) =>
                  onChangeEnd(AudioVolumeKind.ringback, value),
            ),
          _VolumeSlider(
            icon: Icons.add_ic_call_rounded,
            label: 'Call waiting alert',
            description:
                'Repeating beeps during calls; changes apply to the next beep',
            value: levels.callWaiting,
            onChanged: (value) => onChanged(AudioVolumeKind.callWaiting, value),
            onChangeEnd: (value) =>
                onChangeEnd(AudioVolumeKind.callWaiting, value),
          ),
        ],
      ),
    );
  }
}

class _AudioSafetyNotice extends StatelessWidget {
  const _AudioSafetyNotice();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 6, 16, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.hearing_rounded, color: colors.onErrorContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'High levels can be very loud, especially with headphones. Increase gradually.',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}

class _VolumeSlider extends StatelessWidget {
  const _VolumeSlider({
    required this.icon,
    required this.label,
    required this.description,
    required this.value,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final IconData icon;
  final String label;
  final String description;
  final int value;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 2, 8, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Icon(icon, color: colors.onSurfaceVariant),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        label,
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                    ),
                    Text(
                      '$value%',
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: colors.onSurfaceVariant,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
                Text(
                  description,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
                Slider(
                  value: value.toDouble(),
                  min: 0,
                  max: 100,
                  divisions: 20,
                  label: '$value%',
                  onChanged: onChanged,
                  onChangeEnd: onChangeEnd,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String _deviceKey(AudioOutputRouteOption option) =>
    '${option.direction.name}:${option.endpointId ?? option.route.channelValue}';

class _AudioDeviceSectionLabel extends StatelessWidget {
  const _AudioDeviceSectionLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

List<AudioOutputRouteOption> _normalizedRoutes(
  List<AudioOutputRouteOption> routes,
) {
  final endpointRoutes = routes
      .where((option) => option.endpointId != null)
      .toList(growable: false);
  if (endpointRoutes.isNotEmpty) {
    final seen = <String>{};
    final unique = [
      for (final option in endpointRoutes)
        if (seen.add(option.endpointId!)) option,
    ];
    unique.sort((a, b) {
      final type = _routeRank(a.route).compareTo(_routeRank(b.route));
      return type != 0 ? type : a.label.compareTo(b.label);
    });
    return unique;
  }

  AudioOutputRouteOption? find(AudioOutputRoute route) {
    for (final option in routes) {
      if (option.route == route) return option;
    }
    return null;
  }

  final earpiece = find(AudioOutputRoute.earpiece);
  final speaker = find(AudioOutputRoute.speaker);
  final bluetooth = find(AudioOutputRoute.bluetooth);
  final wired = find(AudioOutputRoute.wired);
  final streaming = find(AudioOutputRoute.streaming);

  return [
    AudioOutputRouteOption(
      route: AudioOutputRoute.earpiece,
      label: earpiece?.label ?? AudioOutputRoute.earpiece.defaultLabel,
      available: earpiece?.available ?? true,
    ),
    AudioOutputRouteOption(
      route: AudioOutputRoute.speaker,
      label: speaker?.label ?? AudioOutputRoute.speaker.defaultLabel,
      available: speaker?.available ?? true,
    ),
    if (bluetooth?.available == true)
      AudioOutputRouteOption(
        route: AudioOutputRoute.bluetooth,
        label: bluetooth!.label,
        available: true,
      ),
    if (wired?.available == true) wired!,
    if (streaming?.available == true) streaming!,
  ];
}

bool _isSelected(
  AudioOutputRouteOption option,
  List<AudioOutputRouteOption> options,
  AudioOutputRoute selectedRoute,
) {
  final platformHasSelection = options.any((candidate) => candidate.selected);
  return platformHasSelection ? option.selected : option.route == selectedRoute;
}

int _routeRank(AudioOutputRoute route) => switch (route) {
  AudioOutputRoute.wired => 0,
  AudioOutputRoute.bluetooth => 1,
  AudioOutputRoute.speaker => 2,
  AudioOutputRoute.earpiece => 3,
  AudioOutputRoute.streaming => 4,
};

IconData _iconForRoute(AudioOutputRoute route) {
  return switch (route) {
    AudioOutputRoute.earpiece => AppIcons.call,
    AudioOutputRoute.speaker => AppIcons.speakerOn,
    AudioOutputRoute.bluetooth => AppIcons.bluetooth,
    AudioOutputRoute.wired => Icons.headphones_rounded,
    AudioOutputRoute.streaming => Icons.devices_rounded,
  };
}
