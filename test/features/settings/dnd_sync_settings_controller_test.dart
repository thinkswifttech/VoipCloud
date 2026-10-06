import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/core/constants/storage_keys.dart';
import 'package:phone_app/core/storage/storage_providers.dart';
import 'package:phone_app/core/storage/secure_storage_service.dart';
import 'package:phone_app/features/settings/application/pbx_dnd_monitor.dart';
import 'package:phone_app/features/settings/presentation/pbx_dnd_providers.dart';
import 'package:phone_app/features/settings/presentation/settings_controller.dart';

class _Storage implements SecureStorageService {
  _Storage(this.values);
  final Map<String, String> values;
  bool failWrites = false;
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    if (failWrites) throw StateError('unavailable');
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }

  @override
  Future<void> deleteAll() async {
    values.clear();
  }
}

Future<void> flush() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.value();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final scope in [DndScope.thisDevice, DndScope.allDevices]) {
    test(
      'legacy enabled $scope migration never dials a feature code',
      () async {
        final calls = <MethodCall>[];
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(
          const MethodChannel('voipcloud/linphone'),
          (call) async {
            calls.add(call);
            return null;
          },
        );
        addTearDown(
          () => messenger.setMockMethodCallHandler(
            const MethodChannel('voipcloud/linphone'),
            null,
          ),
        );
        final events = StreamController<Map<String, dynamic>>.broadcast();
        final monitor = PbxDndMonitor(
          events: events.stream,
          start: (_, _) async {},
          stop: () async {},
          toggle: () async {
            fail('restore must not toggle');
          },
          canToggle: () => true,
        );
        final storage = _Storage({
          StorageKeys.appDndEnabled: 'true',
          StorageKeys.appDndScope: scope.name,
        });
        final container = ProviderContainer(
          overrides: [
            secureStorageProvider.overrideWithValue(storage),
            pbxDndMonitorProvider.overrideWithValue(monitor),
          ],
        );
        container.read(settingsControllerProvider);
        await flush();
        expect(
          container.read(settingsControllerProvider).localDndEnabled,
          scope == DndScope.thisDevice,
        );
        expect(
          container.read(settingsControllerProvider).pbxDnd.enabled,
          isNull,
        );
        expect(calls.every((call) => call.method == 'setNativeDnd'), isTrue);
        container
            .read(settingsControllerProvider.notifier)
            .setDndScope(DndScope.allDevices);
        await flush();
        expect(calls.every((call) => call.method == 'setNativeDnd'), isTrue);
        container.dispose();
        monitor.dispose();
        await events.close();
      },
    );
  }
  test(
    'remote PBX state updates switch without toggling or overwriting local DND',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('voipcloud/linphone'),
        (_) async => null,
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          const MethodChannel('voipcloud/linphone'),
          null,
        ),
      );
      final events = StreamController<Map<String, dynamic>>.broadcast(
        sync: true,
      );
      String? epoch;
      int toggles = 0;
      final monitor = PbxDndMonitor(
        events: events.stream,
        start: (_, id) async {
          epoch = id;
        },
        stop: () async {},
        toggle: () async {
          toggles++;
        },
        canToggle: () => true,
      );
      final storage = _Storage({StorageKeys.appLocalDndEnabled: 'true'});
      final container = ProviderContainer(
        overrides: [
          secureStorageProvider.overrideWithValue(storage),
          pbxDndMonitorProvider.overrideWithValue(monitor),
        ],
      );
      container.read(settingsControllerProvider);
      await flush();
      container
          .read(settingsControllerProvider.notifier)
          .setDndScope(DndScope.allDevices);
      monitor.configure(
        identity: '210@swift.voipcloud.ca',
        extension: '210',
        domain: 'swift.voipcloud.ca',
        registered: true,
      );
      await flush();
      events.add({
        'kind': 'notify',
        'extension': '*76210',
        'event': 'dialog',
        'subscriptionId': epoch,
        'contentType': 'application/dialog-info+xml',
        'body':
            '<dialog-info xmlns="urn:ietf:params:xml:ns:dialog-info" version="0" state="full" '
            'entity="sip:*76210@swift.voipcloud.ca"><dialog id="*76210"><state>confirmed</state></dialog></dialog-info>',
      });
      expect(
        container.read(settingsControllerProvider).selectedDndEnabled,
        isTrue,
      );
      expect(
        container.read(settingsControllerProvider).localDndEnabled,
        isTrue,
      );
      expect(toggles, 0);
      storage.failWrites = true;
      container
          .read(settingsControllerProvider.notifier)
          .setDndScope(DndScope.thisDevice);
      container
          .read(settingsControllerProvider.notifier)
          .setDndEnabled(enabled: false);
      await flush();
      expect(
        container.read(settingsControllerProvider).localDndEnabled,
        isFalse,
      );
      expect(container.read(settingsControllerProvider).pbxDnd.enabled, isTrue);
      expect(toggles, 0);
      container.dispose();
      monitor.dispose();
      await events.close();
    },
  );
}
