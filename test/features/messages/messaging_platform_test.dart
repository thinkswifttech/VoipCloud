import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/features/messages/domain/messaging_platform.dart';
import 'package:phone_app/features/messages/domain/carrier_messaging_config.dart';

void main() {
  test('supports launch mobile and desktop targets', () {
    for (final platform in [
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.windows,
      TargetPlatform.macOS,
    ]) {
      expect(
        isCarrierMessagingSupported(web: false, platform: platform),
        isTrue,
      );
    }
  });

  test('excludes web, Linux, and Fuchsia', () {
    expect(
      isCarrierMessagingSupported(web: true, platform: TargetPlatform.android),
      isFalse,
    );
    expect(
      isCarrierMessagingSupported(web: false, platform: TargetPlatform.linux),
      isFalse,
    );
    expect(
      isCarrierMessagingSupported(web: false, platform: TargetPlatform.fuchsia),
      isFalse,
    );
  });

  test('only exposes navigation for an explicitly enabled assignment', () {
    const enabled = CarrierMessagingConfig(
      enabled: true,
      did: '+14165550123',
      inboxId: 'inbox-1',
    );
    const disabled = CarrierMessagingConfig(
      enabled: false,
      did: '+14165550123',
      inboxId: 'inbox-1',
    );

    expect(
      isCarrierMessagingEnabled(
        enabled,
        web: false,
        platform: TargetPlatform.android,
      ),
      isTrue,
    );
    expect(
      isCarrierMessagingEnabled(
        disabled,
        web: false,
        platform: TargetPlatform.android,
      ),
      isFalse,
    );
    expect(
      isCarrierMessagingEnabled(
        null,
        web: false,
        platform: TargetPlatform.android,
      ),
      isFalse,
    );
    expect(
      isCarrierMessagingEnabled(
        enabled,
        web: false,
        platform: TargetPlatform.linux,
      ),
      isFalse,
    );
  });
}
