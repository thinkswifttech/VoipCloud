import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/features/directory/data/dialog_presence_parser.dart';
import 'package:phone_app/features/directory/domain/directory_entry.dart';

void main() {
  test('maps an empty dialog list to available', () {
    final result = parseDialogPresenceEvent({
      'extension': '210',
      'body': '''
        <dialog-info xmlns="urn:ietf:params:xml:ns:dialog-info"
            version="1" state="full" entity="sip:210@tenant.example.test" />
      ''',
    });

    expect(result, DirectoryPresence.available);
  });

  test('maps confirmed and early Asterisk dialogs', () {
    DirectoryPresence? parse(String state) => parseDialogPresenceEvent({
      'extension': '210',
      'body':
          '''
        <dialog-info xmlns="urn:ietf:params:xml:ns:dialog-info">
          <dialog id="1"><state>$state</state></dialog>
        </dialog-info>
      ''',
    });

    expect(parse('confirmed'), DirectoryPresence.busy);
    expect(parse('early'), DirectoryPresence.ringing);
    expect(parse('terminated'), DirectoryPresence.available);
  });

  test('maps a failed subscription to unknown', () {
    expect(
      parseDialogPresenceEvent({
        'kind': 'subscription',
        'extension': '210',
        'state': 'error',
      }),
      DirectoryPresence.unknown,
    );
  });

  test('maps a terminated subscription to unknown', () {
    expect(
      parseDialogPresenceEvent({
        'kind': 'subscription',
        'extension': '210',
        'state': 'terminated',
      }),
      DirectoryPresence.unknown,
    );
  });

  test('does not overwrite presence during subscription setup', () {
    for (final state in ['none', 'progress', 'pending', 'active']) {
      expect(
        parseDialogPresenceEvent({
          'kind': 'subscription',
          'extension': '210',
          'state': state,
        }),
        isNull,
        reason: 'subscription state $state should await a NOTIFY',
      );
    }
  });

  test('ignores malformed notify bodies', () {
    expect(
      parseDialogPresenceEvent({'extension': '210', 'body': '<dialog-info'}),
      isNull,
    );
  });

  test('maps PIDF basic open and closed to reachability', () {
    DirectoryPresence? parse(String state) => parsePidfPresenceEvent({
      'event': 'presence',
      'body':
          '''
        <presence xmlns="urn:ietf:params:xml:ns:pidf">
          <tuple id="extension"><status><basic>$state</basic></status></tuple>
        </presence>
      ''',
    });

    expect(parse('open'), DirectoryPresence.available);
    expect(parse('closed'), DirectoryPresence.unregistered);
  });

  test('dispatches events by SIP package', () {
    final result = parseSipPresenceEvent({
      'event': 'presence',
      'body': '''
        <presence xmlns="urn:ietf:params:xml:ns:pidf">
          <tuple id="extension"><status><basic>closed</basic></status></tuple>
        </presence>
      ''',
    });

    expect(result?.package, SipPresencePackage.presence);
    expect(result?.presence, DirectoryPresence.unregistered);
  });
}
