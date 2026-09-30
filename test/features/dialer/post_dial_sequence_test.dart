import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/features/dialer/domain/post_dial_sequence.dart';

void main() {
  test('plain destination remains unchanged', () {
    final parsed = PostDialSequence.parse(' 211 ');
    expect(parsed.destination, '211');
    expect(parsed.commands, isEmpty);
  });

  test('comma and wait suffix never form part of SIP destination', () {
    final parsed = PostDialSequence.parse('+14165550100,12;34#');
    expect(parsed.destination, '+14165550100');
    expect(parsed.commands, ',12;34#');
  });

  test('does not interpret SIP URI parameters as wait digits', () {
    final parsed = PostDialSequence.parse(
      'sip:211@swift.voipcloud.ca;transport=tcp',
    );

    expect(parsed.destination, 'sip:211@swift.voipcloud.ca;transport=tcp');
    expect(parsed.commands, isEmpty);
  });
}
