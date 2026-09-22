import 'package:flutter_test/flutter_test.dart';
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
}
