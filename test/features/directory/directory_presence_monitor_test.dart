import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/features/directory/data/directory_presence_monitor.dart';
import 'package:phone_app/features/directory/domain/directory_entry.dart';
import 'package:phone_app/features/contacts/domain/quick_dial_entry.dart';
import 'package:phone_app/features/contacts/domain/quick_dial_presence.dart';

DirectoryEntry entry(String number, {bool external = false}) => DirectoryEntry(
  id: number,
  displayName: number,
  numbers: [number],
  telephoneKind: external
      ? DirectoryTelephoneKind.external
      : DirectoryTelephoneKind.internal,
  presence: DirectoryPresence.unknown,
);

void main() {
  test(
    'directory and manual probes share targets and remove disabled probes',
    () async {
      final events = StreamController<Map<String, dynamic>>.broadcast(
        sync: true,
      );
      final starts = <List<String>>[];
      final monitor = DirectoryPresenceMonitor(
        events: events.stream,
        start: (targets) async => starts.add(targets),
        stop: () async {},
      );
      final quick = QuickDialEntry(
        id: 'q',
        displayName: 'Local alias',
        number: '212',
        source: QuickDialSource.custom,
        createdAt: DateTime(2026),
        showBlf: true,
      );
      final probes = quickDialBlfEntries([quick]);
      await monitor.configure([entry('210'), ...probes, entry('212')]);
      expect(starts.single, ['210', '212']);
      expect(monitor.apply(probes).single.presence, DirectoryPresence.unknown);
      events.add({
        'extension': '212',
        'body':
            '<dialog-info><dialog><state>confirmed</state></dialog></dialog-info>',
      });
      expect(monitor.apply(probes).single.presence, DirectoryPresence.busy);
      events.add({
        'extension': '212',
        'kind': 'subscription',
        'state': 'error',
        'event': 'dialog',
      });
      expect(monitor.apply(probes).single.presence, DirectoryPresence.unknown);
      await monitor.configure([
        entry('210'),
        ...quickDialBlfEntries([quick.copyWith(showBlf: false)]),
      ]);
      expect(starts.last, ['210']);
      events.add({'extension': '212', 'body': '<dialog-info/>'});
      expect(monitor.apply(probes).single.presence, DirectoryPresence.unknown);
      await monitor.dispose();
      await events.close();
    },
  );
  test('filters external, unsafe, and duplicate targets', () async {
    final events = StreamController<Map<String, dynamic>>.broadcast(sync: true);
    final starts = <List<String>>[];
    final monitor = DirectoryPresenceMonitor(
      events: events.stream,
      start: (targets) async => starts.add(targets),
      stop: () async {},
    );
    await monitor.configure([
      entry('210'),
      entry('210'),
      entry('211'),
      entry('999', external: true),
      entry('210,1'),
    ]);
    expect(starts, [
      ['210', '211'],
    ]);
    await monitor.dispose();
    await events.close();
  });
  test(
    'live states are shared, stale targets and malformed events ignored',
    () async {
      final events = StreamController<Map<String, dynamic>>.broadcast(
        sync: true,
      );
      final monitor = DirectoryPresenceMonitor(
        events: events.stream,
        start: (_) async {},
        stop: () async {},
      );
      final entries = [entry('210')];
      await monitor.configure(entries);
      events.add({
        'extension': '210',
        'body':
            '<dialog-info><dialog><state>confirmed</state></dialog></dialog-info>',
      });
      expect(monitor.apply(entries).single.presence, DirectoryPresence.busy);
      events.add({'extension': '210', 'body': 'invalid'});
      expect(monitor.apply(entries).single.presence, DirectoryPresence.busy);
      await monitor.configure([entry('211')]);
      events.add({'extension': '210', 'body': '<dialog-info/>'});
      expect(
        monitor.apply([entry('211')]).single.presence,
        DirectoryPresence.unknown,
      );
      await monitor.dispose();
      await events.close();
    },
  );
  test('queued cleanup cannot stop a newer subscription request', () async {
    final events = StreamController<Map<String, dynamic>>.broadcast();
    final gate = Completer<void>();
    final operations = <String>[];
    final monitor = DirectoryPresenceMonitor(
      events: events.stream,
      start: (targets) async {
        operations.add(targets.join(','));
        if (targets.contains('210')) await gate.future;
      },
      stop: () async {
        operations.add('stop');
      },
    );
    final first = monitor.configure([entry('210')]);
    await Future<void>.delayed(Duration.zero);
    final staleCleanup = monitor.configure([]);
    final latest = monitor.configure([entry('211')]);
    gate.complete();
    await Future.wait([first, staleCleanup, latest]);
    expect(operations, ['210', '211']);
    await monitor.dispose();
    await events.close();
  });
  test(
    'subscription failure does not fail directory or block recovery',
    () async {
      final events = StreamController<Map<String, dynamic>>.broadcast();
      var attempts = 0;
      final monitor = DirectoryPresenceMonitor(
        events: events.stream,
        start: (_) async {
          if (++attempts == 1) throw StateError('offline');
        },
        stop: () async {},
      );
      await monitor.configure([entry('210')]);
      expect(
        monitor.apply([entry('210')]).single.presence,
        DirectoryPresence.unknown,
      );
      await monitor.configure([entry('210')]);
      expect(attempts, 2);
      await monitor.dispose();
      await events.close();
    },
  );
}
