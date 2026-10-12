import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/core/storage/secure_storage_service.dart';
import 'package:phone_app/features/directory/data/directory_presence_cache.dart';
import 'package:phone_app/features/directory/data/directory_presence_monitor.dart';
import 'package:phone_app/features/directory/domain/directory_entry.dart';

DirectoryEntry entry(String number, {bool external = false}) => DirectoryEntry(
  id: number,
  displayName: number,
  numbers: [number],
  telephoneKind: external
      ? DirectoryTelephoneKind.external
      : DirectoryTelephoneKind.internal,
  presence: DirectoryPresence.unknown,
);

Map<String, Object> notify(
  String extension,
  DirectoryPresence presence, {
  int generation = 1,
}) => {
  'kind': 'notify',
  'extension': extension,
  'event': 'dialog',
  'generation': generation,
  'body': switch (presence) {
    DirectoryPresence.busy =>
      '<dialog-info><dialog><state>confirmed</state></dialog></dialog-info>',
    DirectoryPresence.ringing =>
      '<dialog-info><dialog><state>early</state></dialog></dialog-info>',
    _ =>
      '<dialog-info><dialog><state>terminated</state></dialog></dialog-info>',
  },
};

void main() {
  test(
    'desired set is sent once per generation and additions are paced deltas',
    () async {
      final events = StreamController<Map<String, dynamic>>.broadcast(
        sync: true,
      );
      final sets = <List<String>>[];
      final additions = <List<String>>[];
      final times = <int>[];
      final clock = Stopwatch()..start();
      final monitor = DirectoryPresenceMonitor(
        events: events.stream,
        setTargets: (targets, _) async {
          sets.add([...targets]);
        },
        reconcile: (_, targets, generation) async {
          additions.add([...targets]);
          times.add(clock.elapsedMilliseconds);
          for (final target in targets) {
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
        stop: () async {},
      );
      final targets = [entry('210'), entry('211'), entry('212')];
      await monitor.configure(
        entries: targets,
        identityKey: 'account',
        registered: true,
      );
      expect(sets.length, 1);
      expect(additions, [
        ['210'],
        ['211'],
        ['212'],
      ]);
      for (var i = 1; i < times.length; i++) {
        expect(times[i] - times[i - 1], greaterThanOrEqualTo(30));
      }
      await monitor.configure(
        entries: targets,
        identityKey: 'account',
        registered: true,
      );
      expect(sets.length, 1);
      await monitor.configure(
        entries: [...targets, entry('213')],
        identityKey: 'account',
        registered: true,
      );
      expect(sets.length, 2);
      expect(additions.last, ['213']);
      await monitor.dispose();
      await events.close();
    },
  );

  test(
    'scrolling throttles off-screen starts and prioritizes visible targets',
    () async {
      final events = StreamController<Map<String, dynamic>>.broadcast(
        sync: true,
      );
      final targets = <String>[];
      final times = <int>[];
      final clock = Stopwatch()..start();
      late DirectoryPresenceMonitor monitor;
      monitor = DirectoryPresenceMonitor(
        events: events.stream,
        reconcile: (_, additions, generation) async {
          targets.addAll(additions);
          times.add(clock.elapsedMilliseconds);
          monitor.prioritizeVisibleTargets(['210']);
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
        stop: () async {},
      );
      monitor.setScrolling(true);
      await monitor.configure(
        entries: [entry('210'), entry('211'), entry('212')],
        startupPriorityTargets: ['210'],
        identityKey: 'account',
        registered: true,
      );
      expect(targets, ['210', '211', '212']);
      expect(times[1] - times[0], greaterThanOrEqualTo(248));
      expect(times[2] - times[1], greaterThanOrEqualTo(248));
      monitor.setScrolling(false);
      await monitor.dispose();
      await events.close();
    },
  );

  test(
    'startup viewport precedes other targets and scrolling reprioritizes only unsent targets',
    () async {
      final events = StreamController<Map<String, dynamic>>.broadcast(
        sync: true,
      );
      final batches = <List<String>>[];
      var stops = 0;
      late DirectoryPresenceMonitor monitor;
      monitor = DirectoryPresenceMonitor(
        events: events.stream,
        stop: () async {
          stops++;
        },
        reconcile: (_, additions, generation) async {
          batches.add([...additions]);
          if (batches.length == 2) {
            monitor.prioritizeVisibleTargets([
              '119',
              '118',
              '119',
              '999',
              '*76210',
            ]);
          }
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
      );
      final entries = [for (var i = 100; i < 120; i++) entry('$i')];
      await monitor.configure(
        entries: entries,
        identityKey: 'account',
        registered: true,
        startupPriorityTargets: ['117', '116'],
      );
      expect(batches.take(2).expand((batch) => batch), ['117', '116']);
      expect(batches.skip(2).take(2).expand((batch) => batch), ['119', '118']);
      final sent = batches.expand((batch) => batch).toList();
      expect(sent.length, 20);
      expect(sent.toSet().length, 20);
      monitor.prioritizeVisibleTargets(['110']);
      await monitor.configure(
        entries: entries,
        identityKey: 'account',
        registered: true,
        startupPriorityTargets: ['110'],
      );
      expect(
        batches.length,
        20,
      ); // No new traffic for an unchanged desired set.
      expect(stops, 0);
      await monitor.dispose();
      await events.close();
    },
  );

  test(
    'slow target does not block progressive loading of healthy targets',
    () async {
      final events = StreamController<Map<String, dynamic>>.broadcast(
        sync: true,
      );
      final batches = <List<String>>[];
      final progressed = Completer<void>();
      late DirectoryPresenceMonitor monitor;
      monitor = DirectoryPresenceMonitor(
        events: events.stream,
        reconcile: (_, additions, generation) async {
          batches.add([...additions]);
          if (batches.length == 2) progressed.complete();
          for (final target in additions.where((target) => target != '100')) {
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
        stop: () async {},
      );
      final loading = monitor.configure(
        entries: [for (var i = 100; i < 150; i++) entry('$i')],
        identityKey: 'account',
        registered: true,
      );
      await progressed.future.timeout(const Duration(milliseconds: 500));
      expect(batches[0], ['100']);
      expect(batches[1], ['101']); // A slow target doesn't block the next pair.
      // Logout interrupts a pending activation wait without waiting two seconds.
      final logout = monitor.configure(
        entries: [],
        identityKey: null,
        registered: false,
      );
      await loading;
      await logout.timeout(const Duration(milliseconds: 500));
      await monitor.dispose();
      await events.close();
    },
  );

  test('partial activation never exceeds eight pending extensions', () async {
    final events = StreamController<Map<String, dynamic>>.broadcast(sync: true);
    final batches = <String>[];
    final eightStarted = Completer<void>();
    final monitor = DirectoryPresenceMonitor(
      events: events.stream,
      reconcile: (_, additions, generation) async {
        for (final target in additions) {
          batches.add(target);
          events.add({
            'kind': 'subscription',
            'extension': target,
            'event': 'dialog',
            'state': 'active',
            'generation': generation,
          });
        }
        if (batches.length == 8) eightStarted.complete();
      },
      stop: () async {},
    );
    final loading = monitor.configure(
      entries: [for (var i = 100; i < 120; i++) entry('$i')],
      identityKey: 'account',
      registered: true,
    );
    await eightStarted.future.timeout(const Duration(seconds: 1));
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(batches, hasLength(8));
    final logout = monitor.configure(
      entries: [],
      identityKey: null,
      registered: false,
    );
    await loading;
    await logout;
    await monitor.dispose();
    await events.close();
  });

  test(
    '150 target burst produces one rendering update with immediate state',
    () async {
      final events = StreamController<Map<String, dynamic>>.broadcast(
        sync: true,
      );
      final monitor = DirectoryPresenceMonitor(
        events: events.stream,
        reconcile: (_, additions, generation) async {
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
        stop: () async {},
      );
      final entries = [for (var i = 100; i < 250; i++) entry('$i')];
      await monitor.configure(
        entries: entries,
        identityKey: 'account',
        registered: true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      var renders = 0;
      final listener = monitor.changes.listen((_) => renders++);
      for (final entry in entries) {
        events.add(notify(entry.extension, DirectoryPresence.busy));
      }
      expect(
        monitor
            .apply(entries)
            .every((e) => e.presence == DirectoryPresence.busy),
        isTrue,
      );
      expect(renders, 0);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(renders, 1);
      await listener.cancel();
      await monitor.dispose();
      await events.close();
    },
  );

  test(
    'same target set is a no-op and live state survives reconfiguration',
    () async {
      final events = StreamController<Map<String, dynamic>>.broadcast(
        sync: true,
      );
      final reconciles = <List<String>>[];
      final monitor = DirectoryPresenceMonitor(
        events: events.stream,
        reconcile: (targets, additions, generation) async {
          reconciles.add([...targets]);
          for (final target in additions) {
            events.add({
              'kind': 'subscription',
              'extension': target,
              'event': 'dialog',
              'state': 'active',
              'generation': generation,
            });
            events.add({
              'kind': 'subscription',
              'extension': target,
              'event': 'presence',
              'state': 'active',
              'generation': generation,
            });
          }
        },
        stop: () async {},
      );
      final entries = [entry('210'), entry('211')];
      await monitor.configure(
        entries: entries,
        identityKey: 'account',
        registered: true,
      );
      events.add(notify('210', DirectoryPresence.busy));
      expect(monitor.apply(entries).first.presence, DirectoryPresence.busy);

      await monitor.configure(
        entries: entries.reversed,
        identityKey: 'account',
        registered: true,
      );
      expect(reconciles, [
        ['210', '211'],
        ['210', '211'],
      ]);
      expect(monitor.apply(entries).first.presence, DirectoryPresence.busy);
      await monitor.dispose();
      await events.close();
    },
  );

  test(
    'target changes reconcile by desired set and discard removed state',
    () async {
      final events = StreamController<Map<String, dynamic>>.broadcast(
        sync: true,
      );
      final desiredSets = <List<String>>[];
      final additions = <List<String>>[];
      final monitor = DirectoryPresenceMonitor(
        events: events.stream,
        reconcile: (targets, batch, generation) async {
          desiredSets.add([...targets]);
          additions.add([...batch]);
          for (final target in batch) {
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
        stop: () async {},
      );
      await monitor.configure(
        entries: [entry('210'), entry('211')],
        identityKey: 'account',
        registered: true,
      );
      events.add(notify('211', DirectoryPresence.busy));
      await monitor.configure(
        entries: [entry('210'), entry('212')],
        identityKey: 'account',
        registered: true,
      );
      expect(desiredSets.last, ['210', '212']);
      expect(additions.last, ['212']);
      expect(
        monitor.apply([entry('211')]).single.presence,
        DirectoryPresence.unknown,
      );
      await monitor.dispose();
      await events.close();
    },
  );

  test('cached lit states are prioritized before available and gray', () async {
    final events = StreamController<Map<String, dynamic>>.broadcast(sync: true);
    final orders = <List<String>>[];
    final monitor = DirectoryPresenceMonitor(
      events: events.stream,
      reconcile: (targets, additions, generation) async {
        orders.add([...targets]);
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
      stop: () async {},
    );
    final entries = [entry('210'), entry('211'), entry('212')];
    await monitor.configure(
      entries: entries,
      identityKey: 'account',
      registered: true,
    );
    events.add(notify('212', DirectoryPresence.busy));
    events.add(notify('211', DirectoryPresence.available));
    await monitor.configure(
      entries: entries,
      identityKey: 'account',
      registered: false,
    );
    await monitor.configure(
      entries: entries,
      identityKey: 'account',
      registered: true,
    );
    expect(orders.last, ['212', '211', '210']);
    await monitor.dispose();
    await events.close();
  });

  test('subscription starts are paced one extension per request', () async {
    final events = StreamController<Map<String, dynamic>>.broadcast(sync: true);
    final batches = <List<String>>[];
    final monitor = DirectoryPresenceMonitor(
      events: events.stream,
      reconcile: (targets, additions, generation) async {
        batches.add([...additions]);
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
      stop: () async {},
    );
    await monitor.configure(
      entries: [for (var index = 100; index < 117; index++) entry('$index')],
      identityKey: 'account',
      registered: true,
    );
    expect(batches.length, 17);
    expect(batches.every((batch) => batch.length == 1), isTrue);
    await monitor.dispose();
    await events.close();
  });

  test('events from an obsolete generation are ignored', () async {
    final events = StreamController<Map<String, dynamic>>.broadcast(sync: true);
    var generation = 0;
    final monitor = DirectoryPresenceMonitor(
      events: events.stream,
      reconcile: (targets, additions, value) async {
        generation = value;
        for (final target in additions) {
          for (final package in ['dialog', 'presence']) {
            events.add({
              'kind': 'subscription',
              'extension': target,
              'event': package,
              'state': 'active',
              'generation': value,
            });
          }
        }
      },
      stop: () async {},
    );
    final entries = [entry('210')];
    await monitor.configure(
      entries: entries,
      identityKey: 'account',
      registered: true,
    );
    await monitor.configure(
      entries: entries,
      identityKey: 'account',
      registered: false,
    );
    await monitor.configure(
      entries: entries,
      identityKey: 'account',
      registered: true,
    );
    events.add(
      notify('210', DirectoryPresence.busy, generation: generation - 1),
    );
    expect(monitor.apply(entries).single.presence, DirectoryPresence.unknown);
    events.add(notify('210', DirectoryPresence.busy, generation: generation));
    expect(monitor.apply(entries).single.presence, DirectoryPresence.busy);
    await monitor.dispose();
    await events.close();
  });

  test('subscription errors preserve last known state as stale', () async {
    final events = StreamController<Map<String, dynamic>>.broadcast(sync: true);
    final monitor = DirectoryPresenceMonitor(
      events: events.stream,
      reconcile: (targets, additions, generation) async {
        for (final package in ['dialog', 'presence']) {
          events.add({
            'kind': 'subscription',
            'extension': '210',
            'event': package,
            'state': 'active',
            'generation': generation,
          });
        }
      },
      stop: () async {},
    );
    final entries = [entry('210')];
    await monitor.configure(
      entries: entries,
      identityKey: 'account',
      registered: true,
    );
    events.add(notify('210', DirectoryPresence.busy));
    events.add({
      'kind': 'subscription',
      'extension': '210',
      'event': 'dialog',
      'state': 'error',
      'generation': 1,
    });
    final result = monitor.apply(entries).single;
    expect(result.presence, DirectoryPresence.busy);
    expect(result.presenceFreshness, DirectoryPresenceFreshness.stale);
    await monitor.dispose();
    await events.close();
  });

  test('failed targets retry with a later native generation', () async {
    final events = StreamController<Map<String, dynamic>>.broadcast(sync: true);
    final retried = Completer<void>();
    var firstGeneration = 0;
    final monitor = DirectoryPresenceMonitor(
      events: events.stream,
      reconcile: (targets, additions, generation) async {
        if (firstGeneration == 0) {
          firstGeneration = generation;
        } else if (generation > firstGeneration && additions.contains('210')) {
          if (!retried.isCompleted) retried.complete();
        }
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
      stop: () async {},
    );
    await monitor.configure(
      entries: [entry('210')],
      identityKey: 'account',
      registered: true,
    );
    events.add({
      'kind': 'subscription',
      'extension': '210',
      'event': 'dialog',
      'state': 'error',
      'generation': firstGeneration,
    });
    await retried.future.timeout(const Duration(seconds: 4));
    await monitor.dispose();
    await events.close();
  });

  test('restores a matching one-minute cache as stale', () async {
    final storage = InMemorySecureStorageService();
    final cache = DirectoryPresenceCache(storage);
    final now = DateTime.utc(2026, 10, 7, 18);
    await cache.write(
      DirectoryPresenceCacheSnapshot(
        identityKey: 'account',
        savedAt: now.subtract(const Duration(seconds: 30)),
        extensions: {
          '210': CachedExtensionPresence(
            dialog: CachedPresenceValue(
              presence: DirectoryPresence.busy,
              observedAt: now.subtract(const Duration(seconds: 30)),
            ),
          ),
        },
      ),
    );
    final events = StreamController<Map<String, dynamic>>.broadcast();
    final monitor = DirectoryPresenceMonitor(
      events: events.stream,
      reconcile: (_, _, _) async {},
      stop: () async {},
      cache: cache,
      now: () => now,
    );
    final entries = [entry('210')];
    await monitor.configure(
      entries: entries,
      identityKey: 'account',
      registered: false,
    );
    final restored = monitor.apply(entries).single;
    expect(restored.presence, DirectoryPresence.busy);
    expect(restored.presenceFreshness, DirectoryPresenceFreshness.stale);
    await monitor.dispose();
    await events.close();
  });

  test('expired and cross-account caches are not restored', () async {
    final storage = InMemorySecureStorageService();
    final cache = DirectoryPresenceCache(storage);
    final now = DateTime.utc(2026, 10, 7, 18);
    await cache.write(
      DirectoryPresenceCacheSnapshot(
        identityKey: 'other-account',
        savedAt: now.subtract(const Duration(minutes: 6)),
        extensions: {
          '210': CachedExtensionPresence(
            dialog: CachedPresenceValue(
              presence: DirectoryPresence.busy,
              observedAt: now,
            ),
          ),
        },
      ),
    );
    expect(await cache.read(identityKey: 'account', now: now), isNull);
    expect(await cache.read(identityKey: 'other-account', now: now), isNull);
  });

  test(
    'recent cache writes do not extend observations older than one minute',
    () async {
      final cache = DirectoryPresenceCache(InMemorySecureStorageService());
      final now = DateTime.utc(2026, 10, 8, 18);
      await cache.write(
        DirectoryPresenceCacheSnapshot(
          identityKey: 'account',
          savedAt: now,
          extensions: {
            '210': CachedExtensionPresence(
              dialog: CachedPresenceValue(
                presence: DirectoryPresence.busy,
                observedAt: now.subtract(const Duration(seconds: 60)),
              ),
            ),
            '211': CachedExtensionPresence(
              dialog: CachedPresenceValue(
                presence: DirectoryPresence.available,
                observedAt: now.subtract(const Duration(seconds: 59)),
              ),
            ),
          },
        ),
      );
      final snapshot = await cache.read(identityKey: 'account', now: now);
      expect(snapshot!.extensions.keys, ['211']);
      expect(
        await cache.read(
          identityKey: 'account',
          now: now.add(const Duration(seconds: 61)),
        ),
        isNull,
      );
    },
  );

  test('ringing older than fifteen seconds restores as unknown', () async {
    final storage = InMemorySecureStorageService();
    final cache = DirectoryPresenceCache(storage);
    final now = DateTime.utc(2026, 10, 7, 18);
    await cache.write(
      DirectoryPresenceCacheSnapshot(
        identityKey: 'account',
        savedAt: now.subtract(const Duration(seconds: 20)),
        extensions: {
          '210': CachedExtensionPresence(
            dialog: CachedPresenceValue(
              presence: DirectoryPresence.ringing,
              observedAt: now.subtract(const Duration(seconds: 20)),
            ),
            availability: CachedPresenceValue(
              presence: DirectoryPresence.available,
              observedAt: now.subtract(const Duration(seconds: 20)),
            ),
          ),
        },
      ),
    );
    final events = StreamController<Map<String, dynamic>>.broadcast();
    final monitor = DirectoryPresenceMonitor(
      events: events.stream,
      reconcile: (_, _, _) async {},
      stop: () async {},
      cache: cache,
      now: () => now,
    );
    final entries = [entry('210')];
    await monitor.configure(
      entries: entries,
      identityKey: 'account',
      registered: false,
    );
    expect(monitor.apply(entries).single.presence, DirectoryPresence.unknown);
    await monitor.dispose();
    await events.close();
  });

  test('logout stops subscriptions and clears visible cached state', () async {
    final events = StreamController<Map<String, dynamic>>.broadcast(sync: true);
    var stops = 0;
    final monitor = DirectoryPresenceMonitor(
      events: events.stream,
      reconcile: (targets, additions, generation) async {
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
      stop: () async => stops++,
    );
    final entries = [entry('210')];
    await monitor.configure(
      entries: entries,
      identityKey: 'account',
      registered: true,
    );
    events.add(notify('210', DirectoryPresence.busy));
    await monitor.configure(
      entries: const [],
      identityKey: null,
      registered: false,
    );
    expect(stops, 1);
    expect(monitor.apply(entries).single.presence, DirectoryPresence.unknown);
    await monitor.dispose();
    await events.close();
  });
}
