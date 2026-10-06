import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/features/settings/presentation/settings_controller.dart';
import 'package:phone_app/features/settings/application/pbx_dnd_monitor.dart';

void main() {
  test('migrates legacy enabled DND to all devices', () {
    expect(
      DndScopeDetails.parse(null, legacyDndEnabled: true),
      DndScope.allDevices,
    );
    expect(
      DndScopeDetails.parse(null, legacyDndEnabled: false),
      DndScope.thisDevice,
    );
  });

  test('device-only DND never toggles PBX DND', () {
    const off = SettingsState();
    const deviceOnly = SettingsState(dndEnabled: true);

    expect(off.pbxDnd.enabled, isNull);
    expect(deviceOnly.pbxDnd.enabled, isNull);
  });

  test('local DND and PBX DND remain independent of selected scope', () {
    const off = SettingsState(dndScope: DndScope.allDevices);
    const allDevices = SettingsState(
      dndEnabled: true,
      dndScope: DndScope.allDevices,
    );
    const thisDevice = SettingsState(
      dndEnabled: true,
      dndScope: DndScope.thisDevice,
    );

    expect(off.pbxDnd.canChange, isFalse);
    expect(allDevices.selectedDndEnabled, isFalse);
    expect(thisDevice.selectedDndEnabled, isTrue);
    final confirmed = allDevices.copyWith(
      pbxDnd: const PbxDndState(enabled: true),
    );
    expect(confirmed.selectedDndEnabled, isTrue);
    expect(
      confirmed.copyWith(dndScope: DndScope.thisDevice).localDndEnabled,
      isTrue,
    );
  });

  test('changing scope while DND is off does not toggle PBX', () {
    const deviceOff = SettingsState();
    const allOff = SettingsState(dndScope: DndScope.allDevices);

    expect(
      deviceOff.copyWith(dndScope: DndScope.allDevices).pbxDnd.enabled,
      isNull,
    );
    expect(allOff.localDndEnabled, isFalse);
  });
}
