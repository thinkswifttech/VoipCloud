import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/features/sip/domain/sip_registration_state.dart';
import 'package:phone_app/features/sip/presentation/calling_status_text.dart';

void main() {
  const jargon = ['sip', 'pbx', 'linphone', 'registr', 'provision', 'diagnos'];

  test('customer-facing calling status text avoids technical words', () {
    for (final status in SipRegistrationStatus.values) {
      final text = [
        CallingStatusText.label(status),
        CallingStatusText.title(status),
        CallingStatusText.description(status),
        CallingStatusText.dialerDetail(status) ?? '',
      ].join(' ').toLowerCase();
      for (final word in jargon) {
        expect(text.contains(word), isFalse, reason: '$status mentions $word');
      }
    }
  });

  test('only a connection problem adds a detail line on the dialer', () {
    expect(
      CallingStatusText.dialerDetail(SipRegistrationStatus.registered),
      isNull,
    );
    expect(
      CallingStatusText.dialerDetail(SipRegistrationStatus.registering),
      isNull,
    );
    expect(
      CallingStatusText.dialerDetail(SipRegistrationStatus.failed),
      isNotNull,
    );
  });
}
