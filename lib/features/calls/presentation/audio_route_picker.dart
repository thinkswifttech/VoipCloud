import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/audio_output_route.dart';
import '../../session/presentation/session_controller.dart';
import '../../../shared/icons/app_icons.dart';

Future<void> showAudioRoutePicker({
  required BuildContext context,
  required WidgetRef ref,
  required AudioOutputRoute selectedRoute,
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
    builder: (sheetContext) {
      return _AudioRoutePickerSheet(
        initialRoute: selectedRoute,
        messenger: messenger,
      );
    },
  );
}

class _AudioRoutePickerSheet extends ConsumerStatefulWidget {
  const _AudioRoutePickerSheet({
    required this.initialRoute,
    required this.messenger,
  });

  final AudioOutputRoute initialRoute;
  final ScaffoldMessengerState messenger;

  @override
  ConsumerState<_AudioRoutePickerSheet> createState() =>
      _AudioRoutePickerSheetState();
}

class _AudioRoutePickerSheetState
    extends ConsumerState<_AudioRoutePickerSheet> {
  List<AudioOutputRouteOption>? _options;
  var _loading = true;
  var _reloadInFlight = false;
  String? _selectingEndpointId;
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
    if (_reloadInFlight || _selectingEndpointId != null) return;
    _reloadInFlight = true;
    try {
      final service = ref.read(sipServiceProvider);
      final options = _normalizedRoutes(await service.getAudioRoutes());
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
    final options = liveEndpoints.isNotEmpty
        ? _normalizedRoutes(liveEndpoints)
        : _options;

    return SafeArea(
      child: Padding(
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
              'Choose where call audio plays.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            if (_loading && options == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (options != null)
              for (final option in options)
                ListTile(
                  enabled: option.available && _selectingEndpointId == null,
                  leading: Icon(_iconForRoute(option.route)),
                  title: Text(option.label),
                  trailing:
                      _selectingEndpointId ==
                          (option.endpointId ?? option.route.channelValue)
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : _isSelected(option, options, selectedRoute)
                      ? Icon(
                          Icons.check_rounded,
                          color: Theme.of(context).colorScheme.primary,
                        )
                      : null,
                  selected: _isSelected(option, options, selectedRoute),
                  onTap: !option.available || _selectingEndpointId != null
                      ? null
                      : () => unawaited(_selectRoute(option)),
                ),
          ],
        ),
      ),
    );
  }

  Future<void> _selectRoute(AudioOutputRouteOption option) async {
    final service = ref.read(sipServiceProvider);
    if (_selectingEndpointId != null) return;
    setState(() {
      _selectingEndpointId = option.endpointId ?? option.route.channelValue;
    });
    try {
      await service.setAudioRoute(option.route, endpointId: option.endpointId);
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (_) {
      if (!mounted) return;
      setState(() => _selectingEndpointId = null);
      widget.messenger.showSnackBar(
        const SnackBar(
          content: Text('That audio device is no longer available.'),
        ),
      );
    }
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
