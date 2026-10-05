import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../voip/platform/voip_platform_channel.dart';
import '../../contacts/domain/quick_dial_presence.dart';
import '../../contacts/presentation/quick_dial_providers.dart';
import '../../session/presentation/session_controller.dart';
import '../data/directory_presence_monitor.dart';
import '../domain/directory_entry.dart';
import 'directory_providers.dart';

final directoryPresenceMonitorProvider = Provider((ref) {
  const platform = VoipPlatformChannel();
  final monitor = DirectoryPresenceMonitor(
    events: platform.presenceEvents(),
    start: platform.startPresenceSubscriptions,
    stop: platform.stopPresenceSubscriptions,
  );
  ref.onDispose(() => unawaited(monitor.dispose()));
  return monitor;
});

/// Shared by Directory and Quick Dial. Disposing one screen cannot stop BLF
/// while the other screen still watches this provider.
final liveDirectoryProvider = StreamProvider.autoDispose<List<DirectoryEntry>>((
  ref,
) {
  final entries =
      ref.watch(directoryProvider).asData?.value ?? const <DirectoryEntry>[];
  final session = ref.watch(sessionControllerProvider).asData?.value;
  final registered =
      ref.watch(sipRegistrationStateProvider).asData?.value.isRegistered ??
      false;
  final monitor = ref.read(directoryPresenceMonitorProvider);
  final usable = session != null && registered;
  final quickEntries = quickDialBlfEntries(
    ref.watch(quickDialProvider).asData?.value ?? const [],
  );
  unawaited(
    monitor.configure(usable ? [...entries, ...quickEntries] : const []),
  );
  ref.onDispose(() => unawaited(monitor.configure(const [])));
  return Stream<List<DirectoryEntry>>.multi((controller) {
    controller.add(usable ? monitor.apply(entries) : entries);
    final subscription = monitor.changes.listen((_) {
      controller.add(usable ? monitor.apply(entries) : entries);
    });
    controller.onCancel = subscription.cancel;
  });
});

/// Shares the subscription owner with Directory without adding probe targets
/// to the visible directory or changing a contact's local alias.
final quickDialLivePresenceProvider =
    StreamProvider.autoDispose<Map<String, DirectoryPresence>>((ref) {
      ref.watch(liveDirectoryProvider);
      final entries = quickDialBlfEntries(
        ref.watch(quickDialProvider).asData?.value ?? const [],
      );
      final monitor = ref.read(directoryPresenceMonitorProvider);
      final usable =
          ref.watch(sessionControllerProvider).asData?.value != null &&
          (ref.watch(sipRegistrationStateProvider).asData?.value.isRegistered ??
              false);
      Map<String, DirectoryPresence> snapshot() => {
        for (final entry in usable ? monitor.apply(entries) : entries)
          entry.extension: entry.presence,
      };
      return Stream<Map<String, DirectoryPresence>>.multi((controller) {
        controller.add(snapshot());
        final subscription = monitor.changes.listen(
          (_) => controller.add(snapshot()),
        );
        controller.onCancel = subscription.cancel;
      });
    });
