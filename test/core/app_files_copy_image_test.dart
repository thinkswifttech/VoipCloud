import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/core/files/downloads_saver.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('voipcloud/files');

  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );

  test('copyImage sends the bytes and mime type to the platform', () async {
    MethodCall? seen;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          seen = call;
          return true;
        });
    final bytes = Uint8List.fromList([1, 2, 3]);

    final copied = await AppFiles().copyImage(
      bytes: bytes,
      mimeType: 'image/png',
    );

    expect(copied, isTrue);
    expect(seen?.method, 'copyImage');
    expect(seen?.arguments['bytes'], bytes);
    expect(seen?.arguments['mimeType'], 'image/png');
  });

  test('copyImage does nothing for empty data', () async {
    var called = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          called = true;
          return true;
        });

    expect(await AppFiles().copyImage(bytes: Uint8List(0)), isFalse);
    expect(called, isFalse);
  });

  test('copyImage reports false when the platform declines', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => false);

    expect(await AppFiles().copyImage(bytes: Uint8List.fromList([9])), isFalse);
  });
}
