import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('carrier messaging feature has no SIP transport dependency', () {
    final files = Directory('lib/features/messages')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'));
    final source = files.map((file) => file.readAsStringSync()).join('\n');

    expect(source, isNot(contains('sipMessagesProvider')));
    expect(source, isNot(contains('SipService')));
    expect(source, isNot(contains('voip_message.dart')));
    expect(source, isNot(contains('sendMessage(destination: destination')));

    final normalized = source.toLowerCase();
    expect(normalized, isNot(contains('voipms')));
    expect(normalized, isNot(contains('voip.ms')));
    expect(normalized, isNot(contains('twilio')));
  });
}
