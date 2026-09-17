import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/features/directory/data/presence_subscription_target.dart';

void main() {
  test('accepts short extensions and full numeric PBX identities', () {
    expect(isPresenceSubscriptionTarget('210'), isTrue);
    expect(isPresenceSubscriptionTarget('4168833878'), isTrue);
    expect(isPresenceSubscriptionTarget('+14168833878'), isTrue);
    expect(isPresenceSubscriptionTarget('123456789012345'), isTrue);
  });

  test('rejects malformed and overlong subscription targets', () {
    expect(isPresenceSubscriptionTarget('1'), isFalse);
    expect(isPresenceSubscriptionTarget('1234567890123456'), isFalse);
    expect(isPresenceSubscriptionTarget('416-883-3878'), isFalse);
    expect(isPresenceSubscriptionTarget('support'), isFalse);
    expect(isPresenceSubscriptionTarget(''), isFalse);
  });

  test('ignores surrounding whitespace', () {
    expect(isPresenceSubscriptionTarget(' 4168833878 '), isTrue);
  });
}
