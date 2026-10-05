import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/features/settings/presentation/windows_always_on_top_tile.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('voipcloud/windows_window');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  Future<void> showTile(WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: WindowsAlwaysOnTopTile())),
    );
    await tester.pumpAndSettle();
  }

  for (final restored in [false, true]) {
    testWidgets('restores saved $restored state', (tester) async {
      messenger.setMockMethodCallHandler(channel, (_) async => restored);
      await showTile(tester);
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        restored,
      );
    });
  }

  testWidgets('waits for successful save before updating', (tester) async {
    final save = Completer<bool>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getAlwaysOnTop') return false;
      expect(call.method, 'setAlwaysOnTop');
      expect(call.arguments, true);
      return save.future;
    });
    await showTile(tester);
    await tester.tap(find.byType(SwitchListTile));
    await tester.pump();
    final pending = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
    expect(pending.value, false);
    expect(pending.onChanged, isNull);
    save.complete(true);
    await tester.pumpAndSettle();
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      true,
    );
  });

  testWidgets('failed save rereads actual state and shows an error', (
    tester,
  ) async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getAlwaysOnTop') return true;
      throw PlatformException(code: 'preference_save_failed');
    });
    await showTile(tester);
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      true,
    );
    expect(
      find.text('Unable to save Always on top. Try again.'),
      findsOneWidget,
    );
  });

  testWidgets('load failure offers retry without inventing a value', (
    tester,
  ) async {
    var fail = true;
    messenger.setMockMethodCallHandler(channel, (_) async {
      if (fail) throw PlatformException(code: 'unavailable');
      return false;
    });
    await showTile(tester);
    expect(find.byType(SwitchListTile), findsNothing);
    fail = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      false,
    );
  });
}
