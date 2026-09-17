import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/audio_output_route.dart';
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

  @override
  void initState() {
    super.initState();
    unawaited(_reloadRoutes());
    // Refresh while open so Bluetooth connect/disconnect appears live.
    _refreshTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(_reloadRoutes(silent: true));
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
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
