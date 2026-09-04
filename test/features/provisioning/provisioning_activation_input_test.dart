import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/features/provisioning/domain/provisioning_activation_input.dart';

void main() {
  test('parses tokenized HTTPS provisioning links', () {
    final input = parseProvisioningInput(
      'https://provision.example.test/activate?token=abc123',
    );

    expect(input, isNotNull);
    expect(input!.backendToken, isNull);
    expect(input.provisioningUri?.scheme, 'https');
  });

  test('uses final HTTPS path segment only for FlexiAPI provisioning', () {
    final input = parseProvisioningInput(
      'https://provision.example.test/provisioning/path-token',
    );

    expect(input, isNotNull);
    expect(input!.backendToken, isNull);
    expect(input.provisioningUri?.host, 'provision.example.test');
  });

  test(
    'parses VoIPCloud deep links without exposing URL in parsed raw value',
    () {
      final input = parseProvisioningInput(
        'voipcloud://provision?token=abc123&url=https%3A%2F%2Fprovision.example.test%2Fsip%3Ftoken%3Dabc123',
      );

      expect(input, isNotNull);
      expect(input!.rawValue, 'abc123');
      expect(input.backendToken, isNull);
      expect(input.provisioningUri?.host, 'provision.example.test');
    },
  );

  test('parses separate backend app-session token when present', () {
    final input = parseProvisioningInput(
      'https://provision.example.test/activate?token=flexi&appSessionToken=backend',
    );

    expect(input, isNotNull);
    expect(input!.backendToken, 'backend');
    expect(input.provisioningUri?.host, 'provision.example.test');
  });

  test('rejects non-VoIPCloud custom scheme links', () {
    expect(parseProvisioningInput('mailto:test@example.com'), isNull);
  });
}
