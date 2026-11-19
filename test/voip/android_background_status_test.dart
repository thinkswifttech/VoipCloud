import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/voip/platform/voip_platform_channel.dart';

void main() {
  test('allowed only when exempt from Doze and not restricted', () {
    expect(const AndroidBackgroundStatus().isAllowed, isTrue);
    expect(const AndroidBackgroundStatus(exempt: false).isAllowed, isFalse);
    expect(const AndroidBackgroundStatus(restricted: true).isAllowed, isFalse);
  });

  test('the restricted standby bucket counts as restricted', () {
    const status = AndroidBackgroundStatus(standbyBucket: 45);
    expect(status.isRestricted, isTrue);
    expect(status.isAllowed, isFalse);
  });

  test('a rarely used app is not flagged', () {
    // Bucket 40 (rare) is what an unused app naturally falls into.
    expect(const AndroidBackgroundStatus(standbyBucket: 40).isAllowed, isTrue);
  });
}
