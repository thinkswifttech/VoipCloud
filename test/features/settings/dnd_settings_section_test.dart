import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/features/settings/presentation/dnd_settings_section.dart';
import 'package:phone_app/features/settings/presentation/settings_controller.dart';
import 'package:phone_app/features/settings/application/pbx_dnd_monitor.dart';

void main() {
  for (final status in [
    const PbxDndState(),
    const PbxDndState(enabled: false, pending: true, message: 'Updating…'),
    const PbxDndState(enabled: true, message: 'Confirmed by PBX'),
  ]) {
    testWidgets(
      'all-device state is explicit and responsive: ${status.message}',
      (tester) async {
        tester.view.physicalSize = const Size(320, 480);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: MediaQuery(
                data: const MediaQueryData(textScaler: TextScaler.linear(2)),
                child: SingleChildScrollView(
                  child: DndSettingsSection(
                    enabled: status.enabled == true,
                    scope: DndScope.allDevices,
                    pbxState: status,
                    onEnabledChanged: (_) {},
                    onScopeChanged: (_) {},
                  ),
                ),
              ),
            ),
          ),
        );
        expect(find.text(status.message), findsOneWidget);
        expect(
          tester
                  .widget<SwitchListTile>(find.byType(SwitchListTile))
                  .onChanged !=
              null,
          status.canChange,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
  for (final width in [320.0, 800.0]) {
    testWidgets('DND order and interactions at width $width', (tester) async {
      DndScope scope = DndScope.thisDevice;
      bool enabled = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: width,
                child: StatefulBuilder(
                  builder: (context, setState) => SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: DndSettingsSection(
                      enabled: enabled,
                      scope: scope,
                      onEnabledChanged: (value) =>
                          setState(() => enabled = value),
                      onScopeChanged: (value) => setState(() => scope = value),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final heading = find.text('Do not disturb');
      final selection = find.byType(SegmentedButton<DndScope>);
      final switchRow = find.byType(SwitchListTile);
      expect(
        tester.getBottomLeft(heading).dy,
        lessThan(tester.getTopLeft(selection).dy),
      );
      expect(
        tester.getBottomLeft(selection).dy,
        lessThan(tester.getTopLeft(switchRow).dy),
      );
      expect(find.text('Applies to: this device'), findsOneWidget);
      await tester.tap(find.text('All devices'));
      await tester.pumpAndSettle();
      expect(scope, DndScope.allDevices);
      expect(enabled, isFalse);
      expect(find.text('Applies to: all devices'), findsOneWidget);
      await tester.tap(find.text('Enable do not disturb'));
      await tester.pumpAndSettle();
      expect(enabled, isTrue);
      expect(tester.widget<SwitchListTile>(switchRow).value, isTrue);
      expect(tester.takeException(), isNull);
    });
  }
}
