import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/features/settings/application/pbx_dnd_monitor.dart';
import 'package:phone_app/features/settings/presentation/dnd_diagnostics_card.dart';
import 'package:phone_app/shared/widgets/app_card.dart';

void main() {
  for (final width in [320.0, 920.0]) {
    testWidgets('aligned card shows status once at width $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var refreshes = 0;
      const message = 'Do not disturb is off for all devices';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(2)),
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const AppCard(
                        title: 'Registration',
                        child: Text('Ready for calls'),
                      ),
                      DndDiagnosticsCard(
                        state: const PbxDndState(
                          enabled: false,
                          message: message,
                        ),
                        registered: true,
                        onRefresh: () => refreshes++,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.text(message), findsOneWidget);
      final cards = find.byType(Card);
      expect(
        tester.getRect(cards.at(0)).left,
        tester.getRect(cards.at(1)).left,
      );
      expect(
        tester.getRect(cards.at(0)).width,
        tester.getRect(cards.at(1)).width,
      );
      await tester.ensureVisible(find.text('Refresh status'));
      await tester.tap(find.text('Refresh status'));
      expect(refreshes, 1);
      expect(tester.takeException(), isNull);
    });
  }
  for (final pending in [true, false]) {
    testWidgets('refresh disabled while ${pending ? "updating" : "offline"}', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DndDiagnosticsCard(
              state: PbxDndState(enabled: false, pending: pending),
              registered: pending,
              onRefresh: () => fail('Disabled refresh must not run'),
            ),
          ),
        ),
      );
      expect(
        tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
        isNull,
      );
    });
  }
}
