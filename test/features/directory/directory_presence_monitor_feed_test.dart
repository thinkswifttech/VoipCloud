import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/core/storage/secure_storage_service.dart';
import 'package:phone_app/features/directory/data/blf_feed_client.dart';
import 'package:phone_app/features/directory/data/directory_presence_cache.dart';
import 'package:phone_app/features/directory/data/directory_presence_monitor.dart';
import 'package:phone_app/features/directory/domain/directory_entry.dart';

DirectoryEntry entry(String number) => DirectoryEntry(
  id: number,
  displayName: number,
  numbers: [number],
  telephoneKind: DirectoryTelephoneKind.internal,
  presence: DirectoryPresence.unknown,
);

class FakeFeed implements BlfFeedSource {
  final controller = StreamController<BlfFeedEvent>.broadcast(sync: true);
  final targets = <Set<String>>[];
  @override
  BlfFeedStatus status = BlfFeedStatus.connecting;

  @override
  Stream<BlfFeedEvent> get events => controller.stream;

  @override
  void setTargets(Set<String> value) => targets.add({...value});

  void snapshot(Map<String, BlfFeedState> states) =>
      controller.add(BlfFeedSnapshot(states));

  void delta(Map<String, BlfFeedState> states) =>
      controller.add(BlfFeedDelta(states));

  void lose(BlfFeedLossReason reason) => controller.add(BlfFeedLost(reason));
}

BlfFeedState feedState(
  DirectoryPresence presence, {
  int observed = 1000,
  bool fresh = true,
}) => BlfFeedState(
  presence: presence,
  observedAt: DateTime.fromMillisecondsSinceEpoch(observed, isUtc: true),
  fresh: fresh,
);

class Rig {
  Rig({
    Duration fallbackDelay = const Duration(milliseconds: 60),
    bool withFeed = true,
    DirectoryPresenceCache? cache,
    DateTime Function()? now,
  }) {
    if (withFeed) feed = FakeFeed();
    monitor = DirectoryPresenceMonitor(
      events: events.stream,
      feed: feed,
      feedFallbackDelay: fallbackDelay,
      cache: cache,
      now: now,
      setTargets: (targets, generation) async {
        sets.add((targets: [...targets], generation: generation));
      },
      reconcile: (_, additions, generation) async {
        additions_.addAll(additions);
        for (final target in additions) {
          for (final package in ['dialog', 'presence']) {
            events.add({
              'kind': 'subscription',
              'extension': target,
              'event': package,
              'state': 'active',
              'generation': generation,
            });
          }
        }
      },
      stop: () async {
        stops += 1;
      },
    );
    monitor.changes.listen((_) => changes += 1);
  }

  FakeFeed? feed;
  late final DirectoryPresenceMonitor monitor;
  final events = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final sets = <({List<String> targets, int generation})>[];
  final additions_ = <String>[];
  int stops = 0;
  int changes = 0;

  Future<void> configure(List<String> numbers, {bool registered = true}) =>
      monitor.configure(
        entries: [for (final number in numbers) entry(number)],
        identityKey: 'account',
        registered: registered,
      );

  DirectoryEntry applied(String number) =>
      monitor.apply([entry(number)]).single;

  Future<void> dispose() async {
    await monitor.dispose();
    await events.close();
  }
}

Future<void> settle([int milliseconds = 150]) =>
    Future<void>.delayed(Duration(milliseconds: milliseconds));

void main() {
  test(
    'an authoritative snapshot is applied as one batch without SIP',
    () async {
      final rig = Rig();
      await rig.configure(['210', '211', '212']);
      expect(rig.feed!.targets.last, {'210', '211', '212'});
      expect(rig.sets, isEmpty);

      rig.feed!.snapshot({
        '210': feedState(DirectoryPresence.busy),
        '211': feedState(DirectoryPresence.available),
        '212': feedState(DirectoryPresence.unregistered),
      });
      await settle();

      expect(rig.changes, 1);
      expect(rig.applied('210').presence, DirectoryPresence.busy);
      expect(rig.applied('211').presence, DirectoryPresence.available);
      expect(rig.applied('212').presence, DirectoryPresence.unregistered);
      expect(
        rig.applied('210').presenceFreshness,
        DirectoryPresenceFreshness.live,
      );
      expect(
        rig.applied('210').presenceObservedAt,
        DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true),
      );
      // Past the fallback delay SIP still has not started.
      await settle(120);
      expect(rig.sets, isEmpty);
      expect(rig.additions_, isEmpty);
      expect(rig.stops, 0);
      await rig.dispose();
    },
  );

  test('feed values are live even while SIP is not registered', () async {
    final rig = Rig();
    await rig.configure(['210'], registered: false);
    rig.feed!.snapshot({'210': feedState(DirectoryPresence.ringing)});
    await settle();
    expect(rig.applied('210').presence, DirectoryPresence.ringing);
    expect(
      rig.applied('210').presenceFreshness,
      DirectoryPresenceFreshness.live,
    );
    await rig.dispose();
  });

  test(
    'deltas update values and unobserved unknown entries are ignored',
    () async {
      final rig = Rig();
      await rig.configure(['210', '211']);
      rig.feed!.snapshot({
        '210': feedState(DirectoryPresence.available),
        '211': const BlfFeedState(
          presence: DirectoryPresence.unknown,
          observedAt: null,
          fresh: false,
        ),
      });
      await settle();
      expect(
        rig.applied('211').presenceFreshness,
        DirectoryPresenceFreshness.unavailable,
      );

      rig.feed!.delta({
        '210': feedState(DirectoryPresence.ringing, observed: 2000),
      });
      await settle();
      expect(rig.applied('210').presence, DirectoryPresence.ringing);
      expect(rig.changes, 2);

      // An older delta does not replace a newer fresh observation.
      rig.feed!.delta({
        '210': feedState(DirectoryPresence.busy, observed: 1500),
      });
      await settle();
      expect(rig.applied('210').presence, DirectoryPresence.ringing);
      await rig.dispose();
    },
  );

  test(
    'retrying loss marks values stale at once, SIP starts after 10 s',
    () async {
      final rig = Rig(fallbackDelay: const Duration(milliseconds: 400));
      await rig.configure(['210', '211']);
      rig.feed!.snapshot({
        '210': feedState(DirectoryPresence.busy),
        '211': feedState(DirectoryPresence.available),
      });
      await settle();
      rig.changes = 0;

      rig.feed!.lose(BlfFeedLossReason.retrying);
      await settle(120);
      expect(rig.applied('210').presence, DirectoryPresence.busy);
      expect(
        rig.applied('210').presenceFreshness,
        DirectoryPresenceFreshness.stale,
      );
      expect(rig.changes, 1);
      expect(rig.sets, isEmpty);

      await settle(450);
      expect(rig.sets.length, 1);
      expect(rig.sets.single.targets, ['210', '211']);
      expect(rig.additions_, ['210', '211']);
      await rig.dispose();
    },
  );

  test('without any snapshot SIP starts after the fallback delay', () async {
    final rig = Rig();
    await rig.configure(['210']);
    await settle(30);
    expect(rig.sets, isEmpty);
    await settle(120);
    expect(rig.sets.single.generation, 1);
    expect(rig.additions_, ['210']);
    await rig.dispose();
  });

  test('an unavailable feed falls back to SIP immediately', () async {
    final rig = Rig(fallbackDelay: const Duration(seconds: 30));
    await rig.configure(['210']);
    rig.feed!.lose(BlfFeedLossReason.unavailable);
    await settle(50);
    expect(rig.additions_, ['210']);
    await rig.dispose();
  });

  test('a paused feed marks values stale but never starts SIP', () async {
    final rig = Rig();
    await rig.configure(['210']);
    rig.feed!.snapshot({'210': feedState(DirectoryPresence.busy)});
    await settle();
    rig.feed!.status = BlfFeedStatus.paused;
    rig.feed!.lose(BlfFeedLossReason.paused);
    await settle(200);
    expect(
      rig.applied('210').presenceFreshness,
      DirectoryPresenceFreshness.stale,
    );
    expect(rig.sets, isEmpty);
    await rig.dispose();
  });

  test('a recovered snapshot stops SIP and fences stale native events', () async {
    final rig = Rig();
    await rig.configure(['210', '211']);
    rig.feed!.lose(BlfFeedLossReason.unavailable);
    await settle(100);
    expect(rig.additions_, ['210', '211']);
    final sipGeneration = rig.sets.single.generation;

    rig.feed!.snapshot({
      '210': feedState(DirectoryPresence.available, observed: 5000),
      '211': feedState(DirectoryPresence.busy, observed: 5000),
    });
    await settle(150);
    expect(rig.stops, 1);
    expect(rig.applied('211').presence, DirectoryPresence.busy);
    expect(
      rig.applied('211').presenceFreshness,
      DirectoryPresenceFreshness.live,
    );

    rig.events.add({
      'kind': 'notify',
      'extension': '211',
      'event': 'dialog',
      'generation': sipGeneration,
      'body':
          '<dialog-info><dialog><state>terminated</state></dialog></dialog-info>',
    });
    await settle(120);
    expect(rig.applied('211').presence, DirectoryPresence.busy);

    // Neither a later retry nor a reconfigure restarts SIP while the feed lives.
    await rig.configure(['210', '211', '212']);
    await settle(150);
    expect(rig.sets.length, 1);
    expect(rig.feed!.targets.last, {'210', '211', '212'});
    await rig.dispose();
  });

  test('feed values are cached like SIP values', () async {
    final storage = InMemorySecureStorageService();
    final cache = DirectoryPresenceCache(storage);
    final now = DateTime.now().toUtc();
    final rig = Rig(cache: cache, now: () => now);
    await rig.configure(['210']);
    rig.feed!.snapshot({
      '210': BlfFeedState(
        presence: DirectoryPresence.busy,
        observedAt: now,
        fresh: true,
      ),
    });
    await settle(700);
    final cached = await cache.read(identityKey: 'account', now: now);
    expect(cached!.extensions['210']!.dialog!.presence, DirectoryPresence.busy);
    await rig.dispose();
  });

  test('without a feed behaviour is SIP only', () async {
    final rig = Rig(withFeed: false);
    await rig.configure(['210']);
    expect(rig.additions_, ['210']);
    expect(rig.sets.length, 1);
    await rig.dispose();
  });

  test(
    'a feed that stays degraded falls back to SIP, recovery hands back',
    () async {
      final rig = Rig(fallbackDelay: const Duration(milliseconds: 80));
      await rig.configure(['210']);
      rig.feed!.snapshot({'210': feedState(DirectoryPresence.busy)});
      await settle();

      rig.feed!.lose(BlfFeedLossReason.retrying);
      await settle(40);
      expect(rig.sets, isEmpty);
      expect(
        rig.applied('210').presenceFreshness,
        DirectoryPresenceFreshness.stale,
      );
      await settle(150);
      expect(rig.additions_, ['210']);

      rig.feed!.snapshot({
        '210': feedState(DirectoryPresence.available, observed: 9000),
      });
      await settle(150);
      expect(rig.stops, 1);
      expect(rig.applied('210').presence, DirectoryPresence.available);
      expect(
        rig.applied('210').presenceFreshness,
        DirectoryPresenceFreshness.live,
      );
      await rig.dispose();
    },
  );

  test(
    'quick-dial probe numbers join the feed targets once and can leave',
    () async {
      final rig = Rig();
      final directory = [entry('210'), entry('211')];
      // Quick Dial BLF probes are extra internal entries; 210 is in both lists.
      final probes = [entry('210'), entry('960'), entry('961')];
      await rig.monitor.configure(
        entries: [...directory, ...probes],
        identityKey: 'account',
        registered: true,
      );
      expect(rig.feed!.targets.last, {'210', '211', '960', '961'});

      rig.feed!.snapshot({
        '210': feedState(DirectoryPresence.busy),
        '960': feedState(DirectoryPresence.ringing),
      });
      await settle();
      expect(rig.applied('960').presence, DirectoryPresence.ringing);
      expect(
        rig.applied('960').presenceFreshness,
        DirectoryPresenceFreshness.live,
      );

      await rig.monitor.configure(
        entries: [...directory, probes.first],
        identityKey: 'account',
        registered: true,
      );
      expect(rig.feed!.targets.last, {'210', '211'});
      expect(
        rig.applied('960').presenceFreshness,
        DirectoryPresenceFreshness.unavailable,
      );
      await rig.dispose();
    },
  );
}
