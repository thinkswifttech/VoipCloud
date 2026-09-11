import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/features/settings/presentation/settings_controller.dart';

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

    expect(shouldTogglePbxDnd(off, deviceOnly), isFalse);
    expect(shouldTogglePbxDnd(deviceOnly, off), isFalse);
  });

  test('entering or leaving enabled all-device scope toggles PBX once', () {
    const off = SettingsState(dndScope: DndScope.allDevices);
    const allDevices = SettingsState(
      dndEnabled: true,
      dndScope: DndScope.allDevices,
    );
    const thisDevice = SettingsState(
      dndEnabled: true,
      dndScope: DndScope.thisDevice,
    );

    expect(shouldTogglePbxDnd(off, allDevices), isTrue);
    expect(shouldTogglePbxDnd(allDevices, off), isTrue);
    expect(shouldTogglePbxDnd(thisDevice, allDevices), isTrue);
    expect(shouldTogglePbxDnd(allDevices, thisDevice), isTrue);
  });

  test('changing scope while DND is off does not toggle PBX', () {
    const deviceOff = SettingsState();
    const allOff = SettingsState(dndScope: DndScope.allDevices);

    expect(shouldTogglePbxDnd(deviceOff, allOff), isFalse);
  });
}
