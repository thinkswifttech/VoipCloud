import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/shared/platform/windows_taskbar_pin_offer.dart';

void main() {
  test('offers taskbar pinning only for an opted-in Windows launch', () {
    expect(
      shouldOfferWindowsTaskbarPin(
        commandLineArguments: const [windowsTaskbarPinOfferArgument],
        platform: TargetPlatform.windows,
        web: false,
      ),
      isTrue,
    );
    expect(
      shouldOfferWindowsTaskbarPin(
        commandLineArguments: const [],
        platform: TargetPlatform.windows,
        web: false,
      ),
      isFalse,
    );
    expect(
      shouldOfferWindowsTaskbarPin(
        commandLineArguments: const [windowsTaskbarPinOfferArgument],
        platform: TargetPlatform.macOS,
        web: false,
      ),
      isFalse,
    );
    expect(
      shouldOfferWindowsTaskbarPin(
        commandLineArguments: const [windowsTaskbarPinOfferArgument],
        platform: TargetPlatform.windows,
        web: true,
      ),
      isFalse,
    );
  });

  testWidgets('requires an in-app click before requesting the native pin', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      const channel = MethodChannel('voipcloud/windows_taskbar');
      final calls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call.method);
        return true;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );

      await tester.pumpWidget(
        const MaterialApp(
          home: WindowsTaskbarPinOffer(
            commandLineArguments: [windowsTaskbarPinOfferArgument],
            child: Scaffold(body: Text('VoipCloud ready')),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(calls, ['canRequestPin']);
      expect(find.text('Pin to taskbar'), findsOneWidget);

      await tester.tap(find.text('Pin to taskbar'));
      await tester.pumpAndSettle();

      expect(calls, ['canRequestPin', 'requestPin']);
      expect(find.text('Pin to taskbar'), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
