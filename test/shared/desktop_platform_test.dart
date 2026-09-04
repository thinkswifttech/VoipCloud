import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/shared/platform/desktop_platform.dart';

void main() {
  test('uses mouse and keyboard UI on supported native desktop builds', () {
    expect(
      isSupportedDesktopPlatform(web: false, platform: TargetPlatform.windows),
      isTrue,
    );
    expect(
      isSupportedDesktopPlatform(web: false, platform: TargetPlatform.macOS),
      isTrue,
    );
  });

  test('keeps touch UI on mobile and does not classify web as desktop', () {
    expect(
      isSupportedDesktopPlatform(web: false, platform: TargetPlatform.android),
      isFalse,
    );
    expect(
      isSupportedDesktopPlatform(web: false, platform: TargetPlatform.iOS),
      isFalse,
    );
    expect(
      isSupportedDesktopPlatform(web: true, platform: TargetPlatform.windows),
      isFalse,
    );
  });
}
