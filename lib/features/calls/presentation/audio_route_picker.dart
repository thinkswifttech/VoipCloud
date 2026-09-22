import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/audio_output_route.dart';
import '../domain/audio_volume_levels.dart';
import '../../session/presentation/session_controller.dart';
import '../../../shared/icons/app_icons.dart';
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
  unawaited(service.ensureBluetoothPermission());

  if (!context.mounted) {
    return;
  }

  await showModalBottomSheet<void>(
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

  @override
  void initState() {
    super.initState();
    unawaited(_reloadRoutes());
    if (widget.choosingDefaults && (Platform.isWindows || Platform.isMacOS)) {
      unawaited(_loadVolumeLevels());
    }
    // Refresh while open so Bluetooth connect/disconnect appears live.
    _refreshTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(_reloadRoutes(silent: true));
    });
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
      Navigator.of(context).maybePop();
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
                  'Audio',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  hasSeparateDevices
                      ? widget.choosingDefaults
                            ? 'Choose the speaker and microphone VoipCloud uses.'
                            : 'Choose a speaker and microphone for this call.'
                      : 'Choose where call audio plays.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                if (_loading && outputs == null)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (outputs != null) ...[
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
      if (option.direction == AudioDeviceDirection.output &&
          !Platform.isWindows &&
          !Platform.isMacOS) {
        Navigator.of(context).pop();
        return;
      }
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
    final current = _volumeLevels;
    if (current == null) return;
    final level = value.round().clamp(0, 100);
    setState(() {
      _volumeLevels = switch (kind) {
        AudioVolumeKind.microphone => AudioVolumeLevels(
          microphone: level,
          callAudio: current.callAudio,
          ringtone: current.ringtone,
        ),
        AudioVolumeKind.callAudio => AudioVolumeLevels(
          microphone: current.microphone,
          callAudio: level,
          ringtone: current.ringtone,
        ),
        AudioVolumeKind.ringtone => AudioVolumeLevels(
          microphone: current.microphone,
          callAudio: current.callAudio,
          ringtone: level,
        ),
      };
    });
    _volumeCommitTimer?.cancel();
    _volumeCommitTimer = Timer(
      const Duration(milliseconds: 100),
      () => unawaited(_saveVolume(kind, level)),
    );
  }

  void _commitVolume(AudioVolumeKind kind, double value) {
    _volumeCommitTimer?.cancel();
    unawaited(_saveVolume(kind, value.round().clamp(0, 100)));
  }

  Future<void> _saveVolume(AudioVolumeKind kind, int level) async {
    try {
      await ref.read(sipServiceProvider).setAudioVolume(kind, level);
    } catch (_) {
      if (!mounted) return;
      widget.messenger.showSnackBar(
        const SnackBar(content: Text('Unable to save that volume level.')),
      );
      await _loadVolumeLevels();
    }
  }
}

class _DesktopVolumeControls extends StatelessWidget {
  const _DesktopVolumeControls({
    required this.levels,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final AudioVolumeLevels levels;
  final void Function(AudioVolumeKind kind, double value) onChanged;
  final void Function(AudioVolumeKind kind, double value) onChangeEnd;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _VolumeSlider(
          icon: Icons.mic_rounded,
          label: 'Microphone',
          description: 'How loudly other people hear you',
          value: levels.microphone,
          onChanged: (value) => onChanged(AudioVolumeKind.microphone, value),
          onChangeEnd: (value) =>
              onChangeEnd(AudioVolumeKind.microphone, value),
        ),
        _VolumeSlider(
          icon: Icons.headphones_rounded,
          label: 'Call audio',
          description: 'Speaker or headset volume during calls',
          value: levels.callAudio,
          onChanged: (value) => onChanged(AudioVolumeKind.callAudio, value),
          onChangeEnd: (value) => onChangeEnd(AudioVolumeKind.callAudio, value),
        ),
        _VolumeSlider(
          icon: Icons.notifications_active_rounded,
          label: 'Incoming call ringtone',
          description: 'Ringing volume before you answer',
          value: levels.ringtone,
          onChanged: (value) => onChanged(AudioVolumeKind.ringtone, value),
          onChangeEnd: (value) => onChangeEnd(AudioVolumeKind.ringtone, value),
        ),
      ],
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
