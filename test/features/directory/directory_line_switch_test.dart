import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/features/accounts/domain/account_models.dart';
import 'package:phone_app/features/accounts/presentation/accounts_controller.dart';
import 'package:phone_app/features/directory/data/directory_presence_monitor.dart';
import 'package:phone_app/features/directory/domain/directory_entry.dart';
import 'package:phone_app/features/directory/presentation/directory_presence_providers.dart';
import 'package:phone_app/features/directory/presentation/directory_providers.dart';
import 'package:phone_app/features/directory/presentation/directory_screen.dart';

// The same extension (102) is a different person on each phone system.
DirectoryEntry _person(String name) => DirectoryEntry(
  id: '102',
  displayName: name,
  numbers: const ['102'],
  telephoneKind: DirectoryTelephoneKind.internal,
  presence: DirectoryPresence.unknown,
);

class _Primary extends DirectoryController {
  @override
  Future<List<DirectoryEntry>> build() async => [_person('Alice Primary')];
}

class _Secondary extends SecondaryDirectoryController {
  @override
  Future<List<DirectoryEntry>> build() async => [_person('Bob Second')];
}

const _lines = [
  LineInfo(
    line: AccountLine.primary,
    label: '210 · swift',
    colorValue: 0xFFD32031,
    config: null,
  ),
  LineInfo(
    line: AccountLine.secondary,
    label: '106 · test',
    colorValue: 0xFF3970C2,
    config: null,
  ),
];

void main() {
  Future<DirectoryPresenceMonitor> monitor() async {
    final events = StreamController<Map<String, dynamic>>.broadcast(sync: true);
    addTearDown(events.close);
    return DirectoryPresenceMonitor(
      events: events.stream,
      reconcile: (_, _, _) async {},
      stop: () async {},
    );
  }

  Future<DirectoryPresenceMonitor> pump(
    WidgetTester tester, {
    required bool hasSecond,
  }) async {
    final presence = await monitor();
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          directoryProvider.overrideWith(_Primary.new),
          secondaryDirectoryProvider.overrideWith(_Secondary.new),
          directoryPresenceMonitorProvider.overrideWithValue(presence),
          hasSecondaryAccountProvider.overrideWithValue(hasSecond),
          accountLinesProvider.overrideWithValue(
            hasSecond ? _lines : [_lines.first],
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: DirectoryScreen())),
      ),
    );
    await tester.pumpAndSettle();
    return presence;
  }

  /// Tears the screen and the presence monitor down so no timer is left over.
  Future<void> finish(
    WidgetTester tester,
    DirectoryPresenceMonitor presence,
  ) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    var disposed = false;
    unawaited(presence.dispose().then((_) => disposed = true));
    for (var i = 0; i < 20 && !disposed; i++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 1));
    }
    expect(disposed, isTrue);
  }

  testWidgets('one account: no switch, the only directory is shown', (
    tester,
  ) async {
    final presence = await pump(tester, hasSecond: false);
    expect(find.text('Alice Primary'), findsOneWidget);
    expect(find.byType(ChoiceChip), findsNothing);
    await finish(tester, presence);
  });

  testWidgets('two accounts: the switch shows each phone system on its own', (
    tester,
  ) async {
    final presence = await pump(tester, hasSecond: true);
    // The choice lives in the expanding options panel, not in a top tab.
    expect(find.text('210 · swift'), findsNothing);
    await tester.tap(find.byTooltip('Sort and account options'));
    await tester.pumpAndSettle();
    expect(find.text('210 · swift'), findsOneWidget);
    expect(find.text('106 · test'), findsOneWidget);
    expect(find.text('Alice Primary'), findsOneWidget);
    expect(find.text('Bob Second'), findsNothing);

    await tester.tap(find.text('106 · test'));
    await tester.pumpAndSettle();
    // Same extension, a different person: only this system's entry appears.
    expect(find.text('Bob Second'), findsOneWidget);
    expect(find.text('Alice Primary'), findsNothing);

    if (find.text('210 · swift').evaluate().isEmpty) {
      await tester.tap(find.byTooltip('Sort and account options'));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('210 · swift'));
    await tester.pumpAndSettle();
    expect(find.text('Alice Primary'), findsOneWidget);
    expect(find.text('Bob Second'), findsNothing);
    await finish(tester, presence);
  });
}
