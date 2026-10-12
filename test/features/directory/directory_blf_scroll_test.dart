import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/features/directory/domain/directory_entry.dart';
import 'package:phone_app/features/directory/data/directory_presence_monitor.dart';
import 'package:phone_app/features/directory/presentation/directory_presence_providers.dart';
import 'package:phone_app/features/directory/presentation/directory_providers.dart';
import 'package:phone_app/features/directory/presentation/directory_screen.dart';

final entries = [
  for (var i = 0; i < 157; i++)
    DirectoryEntry(
      id: '$i',
      displayName: 'Contact ${i.toString().padLeft(3, '0')}',
      numbers: ['${100 + i}'],
      telephoneKind: DirectoryTelephoneKind.internal,
      presence: DirectoryPresence.unknown,
    ),
];

class TestDirectory extends DirectoryController {
  @override
  Future<List<DirectoryEntry>> build() async => entries;
}

void main() {
  testWidgets('BLF bursts preserve scroll position and isolate row repainting', (
    tester,
  ) async {
    final events = StreamController<Map<String, dynamic>>.broadcast(sync: true);
    final monitor = DirectoryPresenceMonitor(
      events: events.stream,
      reconcile: (_, _, _) async {},
      stop: () async {},
    );
    unawaited(
      monitor.configure(
        entries: entries,
        identityKey: 'account',
        registered: false,
      ),
    );
    await tester.binding.setSurfaceSize(const Size(390, 844));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          directoryProvider.overrideWith(TestDirectory.new),
          directoryPresenceMonitorProvider.overrideWithValue(monitor),
        ],
        child: const MaterialApp(home: Scaffold(body: DirectoryScreen())),
      ),
    );
    await tester.pumpAndSettle();
    final listFinder = find.byType(ListView);
    final list = tester.widget<ListView>(listFinder);
    expect(
      (list.childrenDelegate as SliverChildBuilderDelegate)
          .addRepaintBoundaries,
      isTrue,
    );
    await tester.drag(listFinder, const Offset(0, -500));
    await tester.pumpAndSettle();
    final offset = list.controller!.offset;
    expect(offset, greaterThan(0));
    final before = tester.widget<ListView>(listFinder);
    for (final e in entries) {
      events.add({
        'kind': 'notify',
        'extension': e.extension,
        'event': 'dialog',
        'body':
            '<dialog-info><dialog><state>confirmed</state></dialog></dialog-info>',
      });
    }
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    expect(
      identical(tester.widget<ListView>(listFinder), before),
      isTrue,
      reason: 'BLF must not rebuild the directory list',
    );
    expect(tester.widget<ListView>(listFinder).controller!.offset, offset);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    var disposed = false;
    unawaited(monitor.dispose().then((_) => disposed = true));
    for (var i = 0; i < 20 && !disposed; i++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 1));
    }
    expect(disposed, isTrue, reason: 'Monitor teardown must finish');
    var closed = false;
    unawaited(events.close().then((_) => closed = true));
    for (var i = 0; i < 20 && !closed; i++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 1));
    }
    expect(closed, isTrue);
    await tester.binding.setSurfaceSize(null);
  });
}
