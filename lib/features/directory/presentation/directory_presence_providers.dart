import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../voip/platform/voip_platform_channel.dart';
import '../../../core/storage/storage_providers.dart';
import '../../contacts/domain/quick_dial_presence.dart';
import '../../contacts/domain/quick_dial_entry.dart';
import '../../contacts/presentation/quick_dial_providers.dart';
import '../../session/presentation/session_controller.dart';
import 'blf_feed_providers.dart';
import '../data/directory_presence_monitor.dart';
import '../data/directory_presence_cache.dart';
import '../domain/directory_entry.dart';
import 'directory_providers.dart';

typedef PresenceVisualState = ({
  DirectoryPresence? presence,
  DirectoryPresenceFreshness freshness,
});

/// Only mounted indicators subscribe. Metadata and list geometry never receive
/// BLF invalidations; unchanged visual values never rebuild an indicator.
final directoryEntryPresenceProvider = StreamProvider.autoDispose
    .family<PresenceVisualState, DirectoryEntry>((ref, entry) {
      final monitor = ref.watch(directoryPresenceMonitorProvider);
      return _visualChanges(monitor, () {
        final value = monitor.apply([entry]).single;
        return (presence: value.presence, freshness: value.presenceFreshness);
      }, onDispose: ref.onDispose);
    });

final quickDialEntryPresenceProvider = StreamProvider.autoDispose
    .family<PresenceVisualState, QuickDialEntry>((ref, entry) {
      final monitor = ref.watch(directoryPresenceMonitorProvider);
      final directory =
          ref.watch(directoryProvider).value ?? const <DirectoryEntry>[];
      String normalized(String number) =>
          number.trim().replaceAll(RegExp(r'[\s()-]'), '');
      final matches = directory
          .where(
            (candidate) =>
                candidate.isCompany &&
                candidate.numbers.any(
                  (number) => normalized(number) == normalized(entry.number),
                ),
          )
          .toList();
      final probes = quickDialBlfEntries([entry]);
      return _visualChanges(monitor, () {
        final liveMatches = monitor.apply(matches);
        final liveProbes = monitor.apply(probes);
        return (
          presence: quickDialPresence(
            entry,
            liveMatches,
            directStates: {
              for (final probe in liveProbes) probe.extension: probe.presence,
            },
          ),
          freshness: quickDialPresenceFreshness(
            entry,
            liveMatches,
            directFreshness: {
              for (final probe in liveProbes)
                probe.extension: probe.presenceFreshness,
            },
          ),
        );
      }, onDispose: ref.onDispose);
    });

Stream<PresenceVisualState> _visualChanges(
  DirectoryPresenceMonitor monitor,
  PresenceVisualState Function() snapshot, {
  required void Function(void Function()) onDispose,
}) => Stream.multi((controller) {
  var previous = snapshot();
  controller.add(previous);
  final subscription = monitor.changes.listen((_) {
    final next = snapshot();
    if (next != previous) {
      previous = next;
      controller.add(next);
    }
  });
  controller.onCancel = subscription.cancel;
  // Riverpod may pause a stream for an off-screen widget. Cancel our monitor
  // listener explicitly on disposal so session shutdown cannot wait on it.
  onDispose(() {
    unawaited(subscription.cancel());
  });
});

final directoryPresenceMonitorProvider = Provider((ref) {
  const platform = VoipPlatformChannel();
  final monitor = DirectoryPresenceMonitor(
    events: platform.presenceEvents(),
    setTargets: platform.setPresenceTargets,
    reconcile: (_, additions, generation) =>
        platform.enqueuePresenceTargets(additions, generation),
    stop: platform.stopPresenceSubscriptions,
    cache: DirectoryPresenceCache(ref.read(secureStorageProvider)),
    feed: ref.read(blfFeedClientProvider),
  );
  ref.onDispose(() => unawaited(monitor.dispose()));
  return monitor;
});

/// Keeps BLF aligned to the authenticated account rather than a visible page.
/// This provider is watched by the application SIP lifecycle owner.
final directoryPresenceSessionProvider = Provider<void>((ref) {
  final session = ref.watch(sessionControllerProvider).asData?.value;
  final entries =
      ref.watch(directoryProvider).value ?? const <DirectoryEntry>[];
  final quickEntries = quickDialBlfEntries(
    ref.watch(quickDialProvider).value ?? const [],
  );
  // Match the default Directory display order, not extension-number order.
  final startupEntries = entries.where((entry) => entry.isCompany).toList()
    ..sort((a, b) {
      final result = a.displayName.trim().toLowerCase().compareTo(
        b.displayName.trim().toLowerCase(),
      );
      return result != 0 ? result : a.id.compareTo(b.id);
    });
  final registered =
      ref.watch(sipRegistrationStateProvider).asData?.value.isRegistered ??
      false;
  final sip = session?.sipConfig;
  final directory = session?.directoryAccess;
  final identityKey = session == null || sip == null || directory == null
      ? null
      : '${session.user.id}|${sip.sipIdentity}|${directory.endpoint.origin}';
  final feed = ref.read(blfFeedClientProvider);
  if (feed != null) {
    unawaited(
      configureBlfFeedCredentials(
        feed,
        ref.read(secureStorageProvider),
        directory,
      ),
    );
  }
  unawaited(
    ref
        .read(directoryPresenceMonitorProvider)
        .configure(
          entries: [...entries, ...quickEntries],
          identityKey: identityKey,
          registered: registered,
          startupPriorityTargets: startupEntries
              .expand((entry) => entry.numbers)
              .map((number) => number.trim()),
        ),
  );
});

/// Shared by Directory and Quick Dial. Disposing one screen cannot stop BLF
/// while the other screen still watches this provider.
final liveDirectoryProvider = StreamProvider.autoDispose<List<DirectoryEntry>>((
  ref,
) {
  final entries =
      ref.watch(directoryProvider).value ?? const <DirectoryEntry>[];
  final session = ref.watch(sessionControllerProvider).asData?.value;
  final monitor = ref.read(directoryPresenceMonitorProvider);
  final usable = session != null;
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
      final entries = quickDialBlfEntries(
        ref.watch(quickDialProvider).value ?? const [],
      );
      final monitor = ref.read(directoryPresenceMonitorProvider);
      final usable = ref.watch(sessionControllerProvider).asData?.value != null;
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

/// Freshness accompanies the legacy presence map so Quick Dial can distinguish
/// a live NOTIFY from a restored/disconnected last-known value.
final quickDialLivePresenceFreshnessProvider =
    StreamProvider.autoDispose<Map<String, DirectoryPresenceFreshness>>((ref) {
      final entries = quickDialBlfEntries(
        ref.watch(quickDialProvider).value ?? const [],
      );
      final monitor = ref.read(directoryPresenceMonitorProvider);
      final usable = ref.watch(sessionControllerProvider).asData?.value != null;
      Map<String, DirectoryPresenceFreshness> snapshot() => {
        for (final entry in usable ? monitor.apply(entries) : entries)
          entry.extension: entry.presenceFreshness,
      };
      return Stream<Map<String, DirectoryPresenceFreshness>>.multi((
        controller,
      ) {
        controller.add(snapshot());
        final subscription = monitor.changes.listen(
          (_) => controller.add(snapshot()),
        );
        controller.onCancel = subscription.cancel;
      });
    });
