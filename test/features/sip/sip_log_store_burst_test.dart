import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/features/sip/application/sip_log_store.dart';
import 'package:phone_app/voip/platform/voip_platform_channel.dart';

class TestLogPlatform extends VoipPlatformChannel {
  int listeners = 0;
  int cancellations = 0;
  late final events = StreamController<Map<String, dynamic>>.broadcast(
    onListen: () => listeners++,
    onCancel: () => cancellations++,
  );
  @override
  Future<void> setSipLoggingEnabled(bool enabled) async {}
  @override
  Future<void> appendSipLogLine(String line) async {}
  @override
  Future<String> readSipLogFile() async =>
      '2026-10-08T15:00:00Z [INFO] [linphone] File capture continued';
  @override
  Stream<Map<String, dynamic>> sipLogEvents() => events.stream;
}

void main() {
  test(
    'native verbose events are listened to only while a viewer is open',
    () async {
      final platform = TestLogPlatform();
      final store = SipLogStore(platformChannel: platform);
      await store.setEnabled(true);
      expect(platform.listeners, 0);
      var viewer = store.stream.listen((_) {});
      await Future<void>.delayed(Duration.zero);
      expect(platform.listeners, 1);
      await viewer.cancel();
      await Future<void>.delayed(Duration.zero);
      expect(platform.cancellations, 1);
      await store.refreshFromNativeFile();
      expect(store.exportText(), contains('File capture continued'));
      viewer = store.stream.listen((_) {});
      await Future<void>.delayed(Duration.zero);
      expect(platform.listeners, 2);
      await viewer.cancel();
      store.dispose();
      await platform.events.close();
    },
  );
  test('log bursts retain every entry without flooding the viewer', () async {
    final store = SipLogStore();
    var snapshots = 0;
    final subscription = store.stream.listen((_) => snapshots++);
    await Future<void>.delayed(Duration.zero);
    expect(snapshots, 1);
    for (var i = 0; i < 1000; i++) {
      store.append(
        level: 'info',
        source: 'app',
        message: 'Test line $i',
        persist: false,
      );
    }
    expect(store.entries.length, 1000);
    expect(snapshots, 1);
    await Future<void>.delayed(const Duration(milliseconds: 130));
    expect(snapshots, 2);
    expect(store.exportText(), contains('Test line 999'));
    await subscription.cancel();
    store.dispose();
  });

  test('logging without a viewer still retains the full export', () {
    final store = SipLogStore();
    for (var i = 0; i < 5000; i++) {
      store.append(
        level: 'info',
        source: 'app',
        message: 'Test line $i',
        persist: false,
      );
    }
    expect(store.entries.length, SipLogStore.maxEntries);
    expect(store.entries.first.message, 'Test line 1000');
    store.dispose();
  });
}
