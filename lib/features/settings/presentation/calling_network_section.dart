import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../../../voip/platform/voip_platform_channel.dart';
import 'settings_controller.dart';

/// Chooses which connection calls use on a phone. Shown only in builds that
/// ship the native routing, so the setting is never a switch without effect.
class CallingNetworkSection extends ConsumerStatefulWidget {
  const CallingNetworkSection({super.key});

  @override
  ConsumerState<CallingNetworkSection> createState() =>
      _CallingNetworkSectionState();
}

class _CallingNetworkSectionState extends ConsumerState<CallingNetworkSection> {
  StreamSubscription<Map<String, Object?>>? _statusSubscription;
  Map<String, Object?> _status = const {};

  @override
  void initState() {
    super.initState();
    // The native side sends the current status on listen and on every change.
    _statusSubscription = const VoipPlatformChannel()
        .callingNetworkStatusEvents()
        .listen(
          (status) {
            if (mounted) setState(() => _status = status);
          },
          onError: (Object _) {
            // Native status is advisory; keep the last known text.
          },
        );
  }

  @override
  void dispose() {
    unawaited(_statusSubscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = ref.watch(
      settingsControllerProvider.select((state) => state.callingNetwork),
    );
    final description = callingNetworkStatusText(_status, selected);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<CallingNetworkPreference>(
            style: AppTheme.segmentedButtonStyle(theme),
            segments: const [
              ButtonSegment(
                value: CallingNetworkPreference.auto,
                label: Text('Auto'),
              ),
              ButtonSegment(
                value: CallingNetworkPreference.wifi,
                label: Text('Wi‑Fi'),
              ),
              ButtonSegment(
                value: CallingNetworkPreference.cellular,
                label: Text('Mobile data'),
              ),
            ],
            selected: {selected},
            onSelectionChanged: (selection) {
              ref
                  .read(settingsControllerProvider.notifier)
                  .setCallingNetworkPreference(selection.first);
            },
          ),
        ),
        const SizedBox(height: 12),
        Text(
          description,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 4),
        if (selected != CallingNetworkPreference.auto) ...[
          Text(
            'If the connection drops mid-call, the call ends. '
            'Auto keeps calls going.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
        ],
        Text(
          'Mobile data charges may apply.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// Plain-language line describing what calls are using right now.
String callingNetworkStatusText(
  Map<String, Object?> status,
  CallingNetworkPreference requested,
) {
  if (status['enabled'] != true) {
    return 'Calls use the connection your phone chooses.';
  }
  final effective = status['effective'];
  final reason = status['reason'];
  final pending = status['pending'] == true;
  final using = switch (effective) {
    'wifi' => 'Wi‑Fi',
    'cellular' => 'mobile data',
    _ => 'the connection your phone chooses',
  };
  // `pending` also covers short settling pauses, so only a live call may say
  // "after this call".
  if (pending) {
    return status['liveCall'] == true
        ? 'Applies after this call.'
        : 'Switching connection…';
  }
  return switch (reason) {
    'preferred_unavailable' =>
      "Your preferred connection isn't available, so calls use $using.",
    'no_usable_path' =>
      "Couldn't reach VoipCloud on either connection, so your phone chooses.",
    'vpn_active' => 'A VPN is on, so calls use its connection.',
    'preferred' => 'Calls are using $using.',
    _ =>
      requested == CallingNetworkPreference.auto
          ? 'Calls use the connection your phone chooses.'
          : 'Calls are using $using.',
  };
}
