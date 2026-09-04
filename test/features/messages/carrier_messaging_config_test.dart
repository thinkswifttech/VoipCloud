import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/features/messages/domain/carrier_messaging_config.dart';

void main() {
  test('requires enabled assignment, E.164 DID, and inbox ID', () {
    final ready = CarrierMessagingConfig.fromJson({
      'carrier_messaging_enabled': '1',
      'carrier_messaging_did': '+14165550101',
      'carrier_messaging_inbox_id': 'inbox-uuid',
    });
    final incomplete = CarrierMessagingConfig.fromJson({
      'carrier_messaging_enabled': '1',
      'carrier_messaging_did': '4165550101',
    });

    expect(ready.readiness, CarrierMessagingReadiness.ready);
    expect(ready.canUseMessaging, isTrue);
    expect(incomplete.readiness, CarrierMessagingReadiness.incomplete);
  });

  test('distinguishes an unassigned account from a suspended assignment', () {
    const unassigned = CarrierMessagingConfig(
      enabled: false,
      did: '',
      inboxId: '',
    );
    const suspended = CarrierMessagingConfig(
      enabled: false,
      did: '+14165550101',
      inboxId: 'inbox-uuid',
    );

    expect(unassigned.readiness, CarrierMessagingReadiness.notAssigned);
    expect(suspended.readiness, CarrierMessagingReadiness.suspended);
  });
}
