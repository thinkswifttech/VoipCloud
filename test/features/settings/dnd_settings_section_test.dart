import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/features/settings/presentation/dnd_settings_section.dart';
import 'package:phone_app/features/settings/presentation/settings_controller.dart';

void main() {
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
