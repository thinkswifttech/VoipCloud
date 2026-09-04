import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/features/contacts/data/device_contacts_repository.dart';

void main() {
  group('isDeviceContactsSupported', () {
    test('supports native contacts on mobile', () {
      expect(
        isDeviceContactsSupported(web: false, platform: TargetPlatform.android),
        isTrue,
      );
      expect(
        isDeviceContactsSupported(web: false, platform: TargetPlatform.iOS),
        isTrue,
      );
    });

    test('hides native contacts on Windows and macOS', () {
      expect(
        isDeviceContactsSupported(web: false, platform: TargetPlatform.windows),
        isFalse,
      );
      expect(
        isDeviceContactsSupported(web: false, platform: TargetPlatform.macOS),
        isFalse,
      );
    });

    test('does not expose native contacts on web', () {
      expect(
        isDeviceContactsSupported(web: true, platform: TargetPlatform.android),
        isFalse,
      );
    });
  });
}
