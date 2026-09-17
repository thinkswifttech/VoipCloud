import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/voip/platform/voip_platform_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('sends combined badge count with per-feature components', () async {
    const channel = MethodChannel('voipcloud/test_app_badge');
    MethodCall? captured;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          captured = call;
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    await const VoipPlatformChannel(channel: channel).setAppBadgeCount(
      5,
      missedCalls: 2,
      unreadMessages: 3,
    );

    expect(captured?.method, 'setAppBadgeCount');
    expect(captured?.arguments, {
      'count': 5,
      'missedCalls': 2,
      'unreadMessages': 3,
    });
  });

  test('never sends negative badge values', () async {
    const channel = MethodChannel('voipcloud/test_app_badge_nonnegative');
    MethodCall? captured;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          captured = call;
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    await const VoipPlatformChannel(channel: channel).setAppBadgeCount(
      -1,
      missedCalls: -2,
      unreadMessages: -3,
    );

    expect(captured?.arguments, {
      'count': 0,
      'missedCalls': 0,
      'unreadMessages': 0,
    });
  });
}
