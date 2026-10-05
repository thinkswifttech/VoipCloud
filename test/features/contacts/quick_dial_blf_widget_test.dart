import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/core/constants/storage_keys.dart';
import 'package:phone_app/core/storage/secure_storage_service.dart';
import 'package:phone_app/features/contacts/data/local_quick_dial_repository.dart';
import 'package:phone_app/features/contacts/domain/quick_dial_entry.dart';
import 'package:phone_app/features/contacts/presentation/quick_dial_panel.dart';
import 'package:phone_app/features/contacts/presentation/quick_dial_providers.dart';
import 'package:phone_app/features/directory/domain/directory_entry.dart';
import 'package:phone_app/features/directory/presentation/directory_presence_providers.dart';

class MemoryStorage implements SecureStorageService {
  final values = <String, String>{};
  bool failWrites = false;
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    if (failWrites) throw StateError('storage unavailable');
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }

  @override
  Future<void> deleteAll() async => values.clear();
}

void main() {
  final directory = DirectoryEntry(
    id: '210',
    displayName: 'Test',
    numbers: ['210'],
    telephoneKind: DirectoryTelephoneKind.internal,
    presence: DirectoryPresence.busy,
  );

  Future<void> pump(
    WidgetTester tester,
    MemoryStorage storage, {
    Map<String, DirectoryPresence> directStates = const {},
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          quickDialRepositoryProvider.overrideWithValue(
            LocalQuickDialRepository(storage),
          ),
          liveDirectoryProvider.overrideWith(
            (ref) => Stream.value([directory]),
          ),
          quickDialLivePresenceProvider.overrideWith(
            (ref) => Stream.value(directStates),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: QuickDialPanel())),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'manual add sheet saves enabled BLF and resolves a company match',
    (tester) async {
      final storage = MemoryStorage();
      await pump(tester, storage);
      await tester.tap(find.text('Add to Quick Dial'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New number'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), 'Custom Test');
      await tester.enterText(find.byType(TextField).at(1), '210');
      final toggle = find.byType(SwitchListTile);
      await tester.ensureVisible(toggle);
      expect(tester.widget<SwitchListTile>(toggle).value, false);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Add to Quick Dial').last);
      await tester.tap(find.text('Add to Quick Dial').last);
      await tester.pumpAndSettle();
      expect(find.byTooltip('On a call'), findsOneWidget);
      expect(find.text('On a call'), findsNothing);
      final saved =
          jsonDecode(storage.values[StorageKeys.appQuickDial]!) as List;
      expect(saved.single['showBlf'], true);
    },
  );

  testWidgets(
    'directory entry can hide status without editing directory identity',
    (tester) async {
      final storage = MemoryStorage();
      await LocalQuickDialRepository(storage).saveEntries([
        QuickDialEntry(
          id: 'qd',
          displayName: 'Directory Test',
          number: '210',
          source: QuickDialSource.directory,
          createdAt: DateTime(2026),
        ),
      ]);
      await pump(tester, storage);
      expect(find.byTooltip('On a call'), findsOneWidget);
      final avatar = tester.getRect(find.byType(CircleAvatar));
      final badge = tester.getRect(
        find.byKey(const ValueKey('quick-dial-blf-qd')),
      );
      expect(badge.size, const Size(14, 14));
      expect(badge.top, avatar.top);
      expect(badge.right, avatar.right);
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      expect(find.text('Edit'), findsOneWidget);
      expect(find.text('Hide BLF status'), findsNothing);
      expect(find.text('Show BLF status'), findsNothing);
      expect(find.text('Remove'), findsOneWidget);
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      final toggle = find.byType(SwitchListTile);
      await tester.ensureVisible(toggle);
      expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
      await tester.tap(toggle);
      await tester.ensureVisible(find.text('Save changes'));
      await tester.tap(find.text('Save changes'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('On a call'), findsNothing);
      expect(tester.getRect(find.byType(CircleAvatar)), avatar);
      expect(
        (await LocalQuickDialRepository(storage).getEntries()).single.showBlf,
        false,
      );
    },
  );

  testWidgets('unknown manual contact displays unavailable when enabled', (
    tester,
  ) async {
    final storage = MemoryStorage();
    await LocalQuickDialRepository(storage).saveEntries([
      QuickDialEntry(
        id: 'qd',
        displayName: 'Unknown',
        number: '999',
        source: QuickDialSource.custom,
        showBlf: true,
        createdAt: DateTime(2026),
      ),
    ]);
    await pump(tester, storage);
    expect(find.byTooltip('Status unavailable'), findsOneWidget);
    expect(find.text('Offline'), findsNothing);
  });

  test('failed preference persistence is surfaced', () async {
    final storage = MemoryStorage()..failWrites = true;
    await expectLater(
      LocalQuickDialRepository(storage).saveEntries([]),
      throwsStateError,
    );
  });
  testWidgets('manual extension outside directory displays direct PBX badge', (
    tester,
  ) async {
    final storage = MemoryStorage();
    await LocalQuickDialRepository(storage).saveEntries([
      QuickDialEntry(
        id: 'manual',
        displayName: 'My local alias',
        number: '212',
        source: QuickDialSource.custom,
        showBlf: true,
        createdAt: DateTime(2026),
      ),
    ]);
    await pump(
      tester,
      storage,
      directStates: {'212': DirectoryPresence.ringing},
    );
    expect(find.byTooltip('Ringing'), findsOneWidget);
    expect(find.text('My local alias'), findsOneWidget);
    expect(find.text('Ringing'), findsNothing);
    expect(find.byTooltip('Status unavailable'), findsNothing);
  });

  testWidgets(
    'directory name is a persistent local alias, extension and BLF remain intact',
    (tester) async {
      final storage = MemoryStorage();
      final repository = LocalQuickDialRepository(storage);
      await repository.saveEntries([
        QuickDialEntry(
          id: 'qd',
          displayName: directory.displayName,
          number: '210',
          source: QuickDialSource.directory,
          sourceId: directory.id,
          createdAt: DateTime(2026),
        ),
      ]);
      await pump(tester, storage);
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      expect(
        find.text('Changes apply only to Quick Dial, not the directory.'),
        findsOneWidget,
      );
      expect(
        tester.widget<TextField>(find.byType(TextField).at(1)).readOnly,
        true,
      );
      await tester.enterText(find.byType(TextField).at(0), 'My local alias');
      await tester.ensureVisible(find.text('Save changes'));
      await tester.tap(find.text('Save changes'));
      await tester.pumpAndSettle();
      expect(find.text('My local alias'), findsOneWidget);
      expect(find.byTooltip('On a call'), findsOneWidget);
      final saved = (await repository.getEntries()).single;
      expect(saved.displayName, 'My local alias');
      expect(saved.number, '210');
      expect(saved.sourceId, directory.id);
      expect(saved.source, QuickDialSource.directory);
      expect(saved.showBlf, true);
      expect(directory.displayName, 'Test');
      await tester.pumpWidget(const SizedBox.shrink());
      await pump(tester, storage);
      expect(find.text('My local alias'), findsOneWidget);
    },
  );

  test(
    'directory extension is protected even when controller bypasses the form',
    () async {
      final storage = MemoryStorage();
      final repository = LocalQuickDialRepository(storage);
      await repository.saveEntries([
        QuickDialEntry(
          id: 'qd',
          displayName: 'Original',
          number: '210',
          source: QuickDialSource.directory,
          createdAt: DateTime(2026),
        ),
      ]);
      final container = ProviderContainer(
        overrides: [quickDialRepositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(container.dispose);
      await container.read(quickDialProvider.future);
      await expectLater(
        container
            .read(quickDialProvider.notifier)
            .updateEntry(id: 'qd', displayName: 'Alias', number: '211'),
        throwsStateError,
      );
      expect((await repository.getEntries()).single.displayName, 'Original');
    },
  );
}
