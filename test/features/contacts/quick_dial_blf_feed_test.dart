import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/core/config/sip_transport.dart';
import 'package:phone_app/core/storage/secure_storage_service.dart';
import 'package:phone_app/features/contacts/data/local_quick_dial_repository.dart';
import 'package:phone_app/features/contacts/domain/quick_dial_entry.dart';
import 'package:phone_app/features/contacts/presentation/quick_dial_panel.dart';
import 'package:phone_app/features/contacts/presentation/quick_dial_providers.dart';
import 'package:phone_app/features/directory/data/blf_feed_client.dart';
import 'package:phone_app/features/directory/data/directory_presence_monitor.dart';
import 'package:phone_app/features/directory/domain/directory_access.dart';
import 'package:phone_app/features/directory/domain/directory_entry.dart';
import 'package:phone_app/features/directory/presentation/directory_presence_providers.dart';
import 'package:phone_app/features/directory/presentation/directory_providers.dart';
import 'package:phone_app/features/session/domain/app_session.dart';
import 'package:phone_app/features/session/domain/device_status.dart';
import 'package:phone_app/features/session/presentation/session_controller.dart';
import 'package:phone_app/features/sip/domain/sip_config.dart';
import 'package:phone_app/features/sip/domain/sip_registration_state.dart';

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

class MemoryStorage implements SecureStorageService {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
  @override
  Future<void> deleteAll() async => values.clear();
}

final session = AppSession.localSip(
  sipConfig: const SipConfig(
    extension: '100',
    sipUsername: '100',
    authUsername: '100',
    password: 'x',
    domain: 'pbx.example.test',
    registrar: 'pbx.example.test',
    outboundProxy: 'pbx.example.test',
    port: 5060,
    transport: SipTransport.udp,
  ),
  device: const DeviceStatus(
    provisioningStatus: DeviceProvisioningStatus.provisioned,
    sessionStatus: DeviceSessionStatus.active,
    revoked: false,
  ),
  directoryAccess: DirectoryAccess(
    endpoint: Uri.parse('https://dir.example.test/directory'),
    token: 'token',
  ),
);

class _Session extends SessionController {
  @override
  Future<AppSession?> build() async => session;
}

class _Directory extends DirectoryController {
  @override
  Future<List<DirectoryEntry>> build() async => [
    DirectoryEntry(
      id: '210',
      displayName: 'Dir 210',
      numbers: const ['210'],
      telephoneKind: DirectoryTelephoneKind.internal,
      presence: DirectoryPresence.unknown,
    ),
  ];
}

QuickDialEntry quick(String number, {bool blf = true}) => QuickDialEntry(
  id: 'qd-$number',
  displayName: 'Quick $number',
  number: number,
  source: QuickDialSource.custom,
  createdAt: DateTime(2026),
  showBlf: blf,
);

class ControlledRepository extends LocalQuickDialRepository {
  ControlledRepository(super.storage);

  Duration delay = Duration.zero;
  bool fail = false;

  @override
  Future<List<QuickDialEntry>> getEntries() async {
    final loading = delay;
    final failing = fail;
    if (loading > Duration.zero) await Future<void>.delayed(loading);
    if (failing) throw StateError('storage unavailable');
    return super.getEntries();
  }
}

class Rig {
  Rig(List<QuickDialEntry> entries) {
    storage = MemoryStorage();
    repository = ControlledRepository(storage);
    monitor = DirectoryPresenceMonitor(
      events: events.stream,
      feed: feed,
      feedFallbackDelay: const Duration(milliseconds: 250),
      setTargets: (targets, generation) async => sipSets.add([...targets]),
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
      stop: () async => stops += 1,
    );
    seed = repository.saveEntries(entries);
  }

  late final MemoryStorage storage;
  late final ControlledRepository repository;
  late final DirectoryPresenceMonitor monitor;
  late final Future<void> seed;
  final feed = FakeFeed();
  final events = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final sipSets = <List<String>>[];
  int stops = 0;

  List<Override> get overrides => [
    sessionControllerProvider.overrideWith(_Session.new),
    directoryProvider.overrideWith(_Directory.new),
    quickDialRepositoryProvider.overrideWithValue(repository),
    sipRegistrationStateProvider.overrideWith(
      (ref) => Stream.value(
        SipRegistrationState(
          status: SipRegistrationStatus.registered,
          updatedAt: DateTime(2026),
        ),
      ),
    ),
    directoryPresenceMonitorProvider.overrideWithValue(monitor),
  ];

  /// Mirrors the app: the session provider is kept alive and drives configure.
  Future<ProviderContainer> start() async {
    await seed;
    final container = ProviderContainer(overrides: overrides);
    container.listen(directoryPresenceSessionProvider, (_, _) {});
    await container.read(quickDialProvider.future);
    await container.read(directoryProvider.future);
    await container.read(sessionControllerProvider.future);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return container;
  }

  Future<void> dispose(ProviderContainer container) async {
    container.dispose();
    await monitor.dispose();
    await events.close();
  }
}

Future<void> settle([int ms = 150]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

({
  Map<String, DirectoryPresence> presence,
  Map<String, DirectoryPresenceFreshness> freshness,
})
lamps(ProviderContainer container) => (
  presence:
      container.read(quickDialLivePresenceProvider).value ??
      const <String, DirectoryPresence>{},
  freshness:
      container.read(quickDialLivePresenceFreshnessProvider).value ??
      const <String, DirectoryPresenceFreshness>{},
);

Future<void> renderWindow(WidgetTester tester) async {
  // The monitor's 80 ms render window runs on the real clock.
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 150)),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  late Rig rig;
  late ProviderContainer container;
  final listeners = <ProviderSubscription<Object?>>[];

  Future<void> boot(List<QuickDialEntry> entries) async {
    rig = Rig(entries);
    container = await rig.start();
    listeners
      ..add(container.listen(quickDialLivePresenceProvider, (_, _) {}))
      ..add(
        container.listen(quickDialLivePresenceFreshnessProvider, (_, _) {}),
      );
    await settle(40);
  }

  tearDown(() async {
    for (final listener in listeners) {
      listener.close();
    }
    listeners.clear();
    await rig.dispose(container);
  });

  test('hidden quick-dial extensions join the feed targets once', () async {
    await boot([quick('960'), quick('961'), quick('210'), quick('5551234567')]);
    expect(rig.feed.targets.last, {'210', '960', '961'});
    expect(rig.sipSets, isEmpty);
  });

  test(
    'a quick-dial-only extension follows feed deltas in real time',
    () async {
      await boot([quick('960')]);
      rig.feed.snapshot({
        '210': feedState(DirectoryPresence.available),
        '960': feedState(DirectoryPresence.ringing),
      });
      await settle();
      expect(lamps(container).presence['960'], DirectoryPresence.ringing);
      expect(
        lamps(container).freshness['960'],
        DirectoryPresenceFreshness.live,
      );

      var step = 1;
      for (final presence in [
        DirectoryPresence.busy,
        DirectoryPresence.available,
        DirectoryPresence.unregistered,
      ]) {
        rig.feed.delta({
          '960': feedState(presence, observed: 1000 + 100 * step++),
        });
        await settle(120);
        expect(lamps(container).presence['960'], presence);
        expect(
          lamps(container).freshness['960'],
          DirectoryPresenceFreshness.live,
        );
      }
      expect(rig.sipSets, isEmpty);
    },
  );

  test('removing the entry or turning BLF off drops the feed target', () async {
    await boot([quick('960'), quick('961')]);
    expect(rig.feed.targets.last, {'210', '960', '961'});

    await container
        .read(quickDialProvider.notifier)
        .setBlfVisibility('qd-960', false);
    await settle(40);
    expect(rig.feed.targets.last, {'210', '961'});

    await container.read(quickDialProvider.notifier).remove('qd-961');
    await settle(40);
    expect(rig.feed.targets.last, {'210'});
  });

  test('lost feed: stale, SIP after the fallback delay, handed back', () async {
    await boot([quick('960')]);
    rig.feed.snapshot({
      '210': feedState(DirectoryPresence.available),
      '960': feedState(DirectoryPresence.busy),
    });
    await settle();

    rig.feed.lose(BlfFeedLossReason.retrying);
    await settle(120);
    expect(lamps(container).presence['960'], DirectoryPresence.busy);
    expect(lamps(container).freshness['960'], DirectoryPresenceFreshness.stale);

    await settle(300);
    expect(rig.sipSets.single, ['210', '960']);

    rig.feed.snapshot({
      '210': feedState(DirectoryPresence.available, observed: 5000),
      '960': feedState(DirectoryPresence.available, observed: 5000),
    });
    await settle(200);
    expect(rig.stops, 1);
    expect(lamps(container).presence['960'], DirectoryPresence.available);
    expect(lamps(container).freshness['960'], DirectoryPresenceFreshness.live);
  });

  test('a number in both places shows the same state in both', () async {
    final entry = quick('210');
    await boot([entry]);
    rig.feed.snapshot({'210': feedState(DirectoryPresence.ringing)});
    await settle();
    final directorySub = container.listen(liveDirectoryProvider, (_, _) {});
    addTearDown(directorySub.close);
    await settle(40);
    final direct = directorySub.read().value!.single;
    expect(direct.presence, DirectoryPresence.ringing);
    expect(lamps(container).presence['210'], DirectoryPresence.ringing);

    final lampSub = container.listen(
      quickDialEntryPresenceProvider(entry),
      (_, _) {},
    );
    addTearDown(lampSub.close);
    await settle(40);
    final lamp = lampSub.read().value!;
    expect(lamp.presence, DirectoryPresence.ringing);
    expect(lamp.freshness, direct.presenceFreshness);
  });

  group('Quick Dial refresh', () {
    test('a refresh never changes the feed target set', () async {
      await boot([quick('960'), quick('961')]);
      final before = rig.feed.targets.length;
      rig.repository.delay = const Duration(milliseconds: 60);
      final states = <AsyncValue<List<QuickDialEntry>>>[];
      final sub = container.listen(
        quickDialProvider,
        (_, next) => states.add(next),
      );
      final notifier = container.read(quickDialProvider.notifier);
      await Future.wait([notifier.refresh(), notifier.refresh()]);
      await settle(60);
      sub.close();

      expect(states.any((state) => state.isLoading), isTrue);
      expect(
        states.every((state) => state.value?.length == 2),
        isTrue,
        reason: 'the list stays available while reloading',
      );
      expect(rig.feed.targets.length, before);
      expect(rig.feed.targets.last, {'210', '960', '961'});
      expect(rig.sipSets, isEmpty);
    });

    test('a failed refresh keeps the previous list and targets', () async {
      await boot([quick('960')]);
      final before = rig.feed.targets.length;
      rig.repository.fail = true;
      await container.read(quickDialProvider.notifier).refresh();
      await settle(60);
      expect(container.read(quickDialProvider).value!.single.number, '960');
      expect(container.read(quickDialProvider).hasError, isFalse);
      expect(rig.feed.targets.length, before);
    });

    test('adding and removing entries still changes the targets', () async {
      await boot([quick('960')]);
      final notifier = container.read(quickDialProvider.notifier);
      await notifier.add(
        displayName: 'Quick 961',
        number: '961',
        source: QuickDialSource.custom,
        showBlf: true,
      );
      await settle(40);
      expect(rig.feed.targets.last, {'210', '960', '961'});
      await notifier.remove('qd-960');
      await settle(40);
      expect(rig.feed.targets.last, {'210', '961'});
    });

    test('a failed first load is an error and retry recovers', () async {
      rig = Rig([quick('960')]);
      rig.repository.fail = true;
      await rig.seed;
      container = ProviderContainer(overrides: rig.overrides);
      final sub = container.listen(quickDialProvider, (_, _) {});
      await settle(40);
      expect(container.read(quickDialProvider).hasError, isTrue);
      rig.repository.fail = false;
      await container.read(quickDialProvider.notifier).refresh();
      expect(container.read(quickDialProvider).value!.single.number, '960');
      sub.close();
    });
  });

  testWidgets('the Quick Dial panel lamp for a hidden extension updates', (
    tester,
  ) async {
    late final Rig widgetRig;
    late final ProviderContainer widgetContainer;
    await tester.runAsync(() async {
      widgetRig = Rig([quick('960')]);
      widgetContainer = ProviderContainer(overrides: widgetRig.overrides);
      await widgetRig.seed;
      widgetContainer.listen(directoryPresenceSessionProvider, (_, _) {});
      await widgetContainer.read(quickDialProvider.future);
      await widgetContainer.read(directoryProvider.future);
      await widgetContainer.read(sessionControllerProvider.future);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: widgetContainer,
        child: const MaterialApp(home: Scaffold(body: QuickDialPanel())),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(widgetRig.feed.targets.last, {'210', '960'});

    widgetRig.feed.snapshot({
      '210': feedState(DirectoryPresence.available),
      '960': feedState(DirectoryPresence.busy),
    });
    await renderWindow(tester);
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byTooltip('On a call'), findsOneWidget);

    widgetRig.feed.delta({
      '960': feedState(DirectoryPresence.ringing, observed: 2000),
    });
    await renderWindow(tester);
    expect(find.byTooltip('Ringing'), findsOneWidget);

    widgetRig.feed.lose(BlfFeedLossReason.paused);
    await renderWindow(tester);
    expect(find.byTooltip('Last known: Ringing. Updating.'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    widgetContainer.dispose();
    await tester.runAsync(() async {
      await widgetRig.monitor.dispose();
      await widgetRig.events.close();
    });
  });
}
