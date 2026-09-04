import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/features/dialer/presentation/dialer_input_platform.dart';

void main() {
  group('supportsDesktopDialerKeyboard', () {
    test('enables keyboard entry on Windows and macOS', () {
      expect(
        supportsDesktopDialerKeyboard(
          web: false,
          platform: TargetPlatform.windows,
        ),
        isTrue,
      );
      expect(
        supportsDesktopDialerKeyboard(
          web: false,
          platform: TargetPlatform.macOS,
        ),
        isTrue,
      );
    });

    test('keeps mobile and web on the existing input behavior', () {
      expect(
        supportsDesktopDialerKeyboard(
          web: false,
          platform: TargetPlatform.android,
        ),
        isFalse,
      );
      expect(
        supportsDesktopDialerKeyboard(web: false, platform: TargetPlatform.iOS),
        isFalse,
      );
      expect(
        supportsDesktopDialerKeyboard(
          web: true,
          platform: TargetPlatform.windows,
        ),
        isFalse,
      );
    });
  });

  group('dtmfCharacterFromKeyboard', () {
    test('accepts the standard DTMF keys', () {
      for (final character in '0123456789*#'.split('')) {
        expect(dtmfCharacterFromKeyboard(character), character);
      }
    });

    test('rejects non-DTMF keyboard input', () {
      expect(dtmfCharacterFromKeyboard(null), isNull);
      expect(dtmfCharacterFromKeyboard(''), isNull);
      expect(dtmfCharacterFromKeyboard('+'), isNull);
      expect(dtmfCharacterFromKeyboard('A'), isNull);
      expect(dtmfCharacterFromKeyboard('12'), isNull);
    });
  });
}
