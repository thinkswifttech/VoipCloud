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

  test('ignores spaces and line breaks inside a pasted setup link', () {
    final input = parseProvisioningInput(
      ' https://provision.example.test/provi\n sioning/path-token ',
    );

    expect(input, isNotNull);
    expect(
      input!.provisioningUri.toString(),
      'https://provision.example.test/provisioning/path-token',
    );
  });

  group('provisioningInputProblem', () {
    String? problem(String input) =>
        provisioningInputProblem(input, allowedDomain: '');

    test('accepts a normal setup link, token and deep link', () {
      expect(
        problem('https://swift.sip.example.test/provisioning/abc'),
        isNull,
      );
      expect(problem('abc123'), isNull);
      expect(problem('voipcloud://provision?token=abc123'), isNull);
    });

    test('explains empty, non-https, malformed and incomplete links', () {
      expect(problem('  '), contains('Paste the setup link'));
      expect(
        problem('http://x.example.test/provisioning/abc'),
        contains('https://'),
      );
      expect(
        problem('ftp://x.example.test/abc'),
        contains("doesn't look like a setup link"),
      );
      expect(
        problem('https://localhost/provisioning/abc'),
        contains('web address'),
      );
      expect(
        problem('https://swift..example.test/provisioning/abc'),
        contains('web address'),
      );
      expect(problem('https://swift.example.test/'), contains('incomplete'));
    });

    test('only accepts hosts under the allowed domain', () {
      String? vc(String input) => provisioningInputProblem(input);
      expect(vc('https://swift.sip.voipcloud.ca/provisioning/abc'), isNull);
      expect(vc('https://a.b.c.voipcloud.ca/provisioning/abc'), isNull);
      expect(vc('https://SWIFT.sip.VoipCloud.ca/provisioning/abc'), isNull);
      const notVoipCloud = "isn't from VoipCloud";
      expect(
        vc('https://voipcloud.ca/provisioning/abc'),
        contains(notVoipCloud),
      );
      expect(
        vc('https://evil.example.com/provisioning/abc'),
        contains(notVoipCloud),
      );
      expect(
        vc('https://voipcloud.ca.evil.com/provisioning/abc'),
        contains(notVoipCloud),
      );
      expect(
        vc('https://notvoipcloud.ca/provisioning/abc'),
        contains(notVoipCloud),
      );
      expect(
        vc('https://swift.sip.voipcloud.ca@evil.example.com/provisioning/abc'),
        contains(notVoipCloud),
      );
      expect(
        vc(
          'voipcloud://provision?token=abc&url=https%3A%2F%2Fevil.example.com%2Fx',
        ),
        contains(notVoipCloud),
      );
    });
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
