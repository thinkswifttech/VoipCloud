import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/app/router/external_communication_intent_listener.dart';

void main() {
  test('external call destination is carried by the dialer route', () {
    final location = externalCallDialerLocation('+1 (416) 555-0100');
    final uri = Uri.parse(location);

    expect(uri.path, '/dialer');
    expect(uri.queryParameters['to'], '+1 (416) 555-0100');
  });
}
