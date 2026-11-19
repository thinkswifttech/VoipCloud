import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/features/settings/presentation/calling_network_section.dart';
import 'package:phone_app/features/settings/presentation/settings_controller.dart';

void main() {
  group('CallingNetworkPreference', () {
    test('parses stored values and defaults to automatic', () {
      expect(
        CallingNetworkPreferenceDetails.parse('wifi'),
        CallingNetworkPreference.wifi,
      );
      expect(
        CallingNetworkPreferenceDetails.parse('cellular'),
        CallingNetworkPreference.cellular,
      );
      expect(
        CallingNetworkPreferenceDetails.parse(null),
        CallingNetworkPreference.auto,
      );
      expect(
        CallingNetworkPreferenceDetails.parse('bogus'),
        CallingNetworkPreference.auto,
      );
    });

    test('a fresh settings state is automatic', () {
      expect(
        const SettingsState().callingNetwork,
        CallingNetworkPreference.auto,
      );
    });
  });

  group('callingNetworkStatusText', () {
    String text(Map<String, Object?> status, CallingNetworkPreference p) =>
        callingNetworkStatusText(status, p);

    test('says the phone chooses when routing is off or unknown', () {
      expect(
        text(const {}, CallingNetworkPreference.cellular),
        'Calls use the connection your phone chooses.',
      );
      expect(
        text({'enabled': false}, CallingNetworkPreference.wifi),
        'Calls use the connection your phone chooses.',
      );
    });

    test('names the connection in use', () {
      expect(
        text({
          'enabled': true,
          'effective': 'cellular',
          'reason': 'preferred',
        }, CallingNetworkPreference.cellular),
        'Calls are using mobile data.',
      );
    });

    test('explains a fallback without technical terms', () {
      expect(
        text({
          'enabled': true,
          'effective': 'wifi',
          'reason': 'preferred_unavailable',
        }, CallingNetworkPreference.cellular),
        "Your preferred connection isn't available, so calls use Wi‑Fi.",
      );
    });

    test('shows a change that waits for the current call', () {
      expect(
        text({
          'enabled': true,
          'effective': 'system',
          'reason': 'preferred',
          'pending': true,
          'liveCall': true,
        }, CallingNetworkPreference.wifi),
        'Applies after this call.',
      );
    });

    test('does not mention a call when none is active', () {
      expect(
        text({
          'enabled': true,
          'effective': 'system',
          'reason': 'preferred',
          'pending': true,
          'liveCall': false,
        }, CallingNetworkPreference.wifi),
        'Switching connection…',
      );
    });

    test('mentions a VPN and an unreachable service plainly', () {
      expect(
        text({
          'enabled': true,
          'effective': 'system',
          'reason': 'vpn_active',
        }, CallingNetworkPreference.cellular),
        'A VPN is on, so calls use its connection.',
      );
      expect(
        text({
          'enabled': true,
          'effective': 'system',
          'reason': 'no_usable_path',
        }, CallingNetworkPreference.cellular),
        startsWith("Couldn't reach VoipCloud on either connection"),
      );
    });
  });
}
