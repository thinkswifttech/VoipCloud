import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/features/accounts/domain/account_line.dart';
import 'package:phone_app/features/calls/domain/call_direction.dart';
import 'package:phone_app/features/calls/domain/call_status.dart';
import 'package:phone_app/features/calls/domain/voip_call.dart';
import 'package:phone_app/features/calls/presentation/caller_identity.dart';
import 'package:phone_app/features/contacts/domain/contact.dart';
import 'package:phone_app/features/contacts/domain/quick_dial_entry.dart';
import 'package:phone_app/features/directory/domain/directory_entry.dart';

void main() {
  test('detects an existing contact using normalized message identity', () {
    const contact = Contact(
      id: 'contact-1',
      displayName: 'Saved Person',
      phoneNumber: '+1 (416) 555-0123',
    );

    expect(
      contactMatchesRemoteIdentity(
        contact,
        'sip:+14165550123@tenant.example.test',
      ),
      isTrue,
    );
    expect(contactMatchesRemoteIdentity(contact, '+14165550999'), isFalse);
  });

  test('preserves a prefixed SIP caller identifier', () {
    final identity = resolveRemoteIdentity(
      remoteUri: 'sip:sup:204@tenant.example.test',
      remoteDisplayName: '204',
      contacts: const [],
      directory: const [],
    );

    expect(identity.label, 'sup:204');
    expect(identity.number, 'sup:204');
  });

  test('decodes an encoded prefix in the SIP user part', () {
    final identity = resolveRemoteIdentity(
      remoteUri: 'sip:sup%3A204@tenant.example.test',
      contacts: const [],
      directory: const [],
    );

    expect(identity.label, 'sup:204');
    expect(identity.number, 'sup:204');
  });

  test('keeps the prefixed identifier when resolving a directory name', () {
    final directory = [
      DirectoryEntry(
        id: '204',
        displayName: 'Support Desk',
        numbers: ['204'],
        telephoneKind: DirectoryTelephoneKind.internal,
        presence: DirectoryPresence.unknown,
      ),
    ];

    final identity = resolveRemoteIdentity(
      remoteUri: 'sip:sup:204@tenant.example.test',
      contacts: const [],
      directory: directory,
    );

    expect(identity.label, 'sup: Support Desk');
    expect(identity.number, 'sup:204');
    expect(identity.isResolvedName, isTrue);
  });

  test('keeps a queue prefix when resolving a device contact', () {
    final identity = resolveRemoteIdentity(
      remoteUri: 'sip:sales%3A14165550123@tenant.example.test',
      remoteDisplayName: 'Incoming caller',
      contacts: const [
        Contact(
          id: 'contact-1',
          displayName: 'Example Agent',
          phoneNumber: '+1 416 555 0123',
        ),
      ],
      directory: const [],
    );

    expect(identity.label, 'sales: Example Agent');
    expect(identity.number, 'sales:14165550123');
  });

  test('does not duplicate a queue prefix already present in display name', () {
    final identity = resolveRemoteIdentity(
      remoteUri: 'sip:sales:204@tenant.example.test',
      remoteDisplayName: 'sales: Support Desk',
      contacts: const [],
      directory: const [],
    );

    expect(identity.label, 'sales: Support Desk');
  });

  test('preserves a queue prefix supplied only in SIP display name', () {
    final identity = resolveRemoteIdentity(
      remoteUri: 'sip:14165550123@tenant.example.test',
      remoteDisplayName: 'Support Queue: External caller',
      contacts: const [
        Contact(
          id: 'contact-1',
          displayName: 'Example Agent',
          phoneNumber: '+1 416 555 0123',
        ),
      ],
      directory: const [],
    );

    expect(identity.label, 'Support Queue: Example Agent');
  });

  test('preserves a queue prefix for a caller not saved anywhere', () {
    final identity = resolveRemoteIdentity(
      remoteUri: 'sip:14165550123@tenant.example.test',
      remoteDisplayName: 'SUP: Abdul',
      contacts: const [],
      directory: const [],
    );

    expect(identity.label, 'SUP: Abdul');
    expect(identity.number, '14165550123');
  });

  test('preserves a queue prefix from a quoted server display name', () {
    final identity = resolveRemoteIdentity(
      remoteUri: 'sip:211@tenant.example.test',
      remoteDisplayName: '"TEST:Abdul Test User"',
      contacts: const [
        Contact(
          id: 'contact-1',
          displayName: 'Abdul Test User',
          phoneNumber: '211',
        ),
      ],
      directory: const [],
    );

    expect(identity.label, 'TEST: Abdul Test User');
    expect(identity.number, '211');
  });

  test('preserves a queue prefix when resolving a Quick Dial entry', () {
    final identity = resolveRemoteIdentity(
      remoteUri: 'sip:14165550123@tenant.example.test',
      remoteDisplayName: 'SUP: External caller',
      contacts: const [],
      quickDial: [
        QuickDialEntry(
          id: 'quick-1',
          displayName: 'Abdul',
          number: '+1 416 555 0123',
          source: QuickDialSource.custom,
          createdAt: DateTime.utc(2026, 9, 20),
        ),
      ],
      directory: const [],
    );

    expect(identity.label, 'SUP: Abdul');
    expect(identity.number, '14165550123');
  });

  test('continues to normalize ordinary telephone callers', () {
    final identity = resolveRemoteIdentity(
      remoteUri: 'sip:+1 (416) 555-0123@tenant.example.test',
      contacts: const [],
      directory: const [],
    );

    expect(identity.label, '+14165550123');
    expect(identity.number, '+14165550123');
  });

  group('two accounts with the same extension', () {
    // The loaded directory belongs to the primary phone system.
    final primaryDirectory = [
      DirectoryEntry(
        id: '102',
        displayName: 'Primary System Person',
        numbers: const ['102'],
        telephoneKind: DirectoryTelephoneKind.internal,
        presence: DirectoryPresence.unknown,
      ),
    ];

    VoipCall callOn(AccountLine? line) => VoipCall(
      id: 'c1',
      remoteUri: 'sip:102@tenant.example.test',
      direction: CallDirection.incoming,
      status: CallStatus.ringing,
      startedAt: DateTime(2026, 10, 29),
      line: line,
    );

    test('a call on the primary line may use the primary directory', () {
      final identity = resolveCallerIdentity(
        call: callOn(AccountLine.primary),
        contacts: const [],
        directory: primaryDirectory,
      );
      expect(identity.label, 'Primary System Person');
    });

    test('a call on the second line never borrows a name from it', () {
      final identity = resolveCallerIdentity(
        call: callOn(AccountLine.secondary),
        contacts: const [],
        directory: primaryDirectory,
      );
      expect(identity.isResolvedName, isFalse);
      expect(identity.label, '102');
    });

    test('a call on the second line is named from the second directory', () {
      final secondDirectory = [
        DirectoryEntry(
          id: '102',
          displayName: 'Second System Person',
          numbers: const ['102'],
          telephoneKind: DirectoryTelephoneKind.internal,
          presence: DirectoryPresence.unknown,
        ),
      ];
      final onSecond = resolveCallerIdentity(
        call: callOn(AccountLine.secondary),
        contacts: const [],
        directory: primaryDirectory,
        secondaryDirectory: secondDirectory,
      );
      expect(onSecond.label, 'Second System Person');
      // The same extension on the primary line is still the primary person.
      final onPrimary = resolveCallerIdentity(
        call: callOn(AccountLine.primary),
        contacts: const [],
        directory: primaryDirectory,
        secondaryDirectory: secondDirectory,
      );
      expect(onPrimary.label, 'Primary System Person');
    });

    test('a call with no line (single account) is unchanged', () {
      final identity = resolveCallerIdentity(
        call: callOn(null),
        contacts: const [],
        directory: primaryDirectory,
      );
      expect(identity.label, 'Primary System Person');
    });
  });
}
