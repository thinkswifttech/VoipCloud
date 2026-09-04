import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/features/directory/data/directory_repository.dart';
import 'package:phone_app/features/directory/domain/directory_entry.dart';

void main() {
  test('parses normalized directory gateway response', () {
    final entries = parseDirectoryResponse({
      'contacts': [
        {
          'id': 'example-210',
          'displayName': 'Example Support',
          'extension': '210',
          'numbers': ['210', '4165550123'],
          'company': 'Example Company',
          'teams': ['Example Accounting', 'Example Operations'],
          'type': 'internal',
          'presence': 'unknown',
          'deviceRegistered': true,
        },
      ],
    });

    expect(entries, hasLength(1));
    expect(entries.single.extension, '210');
    expect(entries.single.numbers, ['210', '4165550123']);
    expect(entries.single.telephoneKind, DirectoryTelephoneKind.internal);
    expect(entries.single.teams, ['Example Accounting', 'Example Operations']);
    expect(entries.single.presence, DirectoryPresence.unknown);
    expect(entries.single.deviceRegistered, isTrue);
  });

  test('keeps one normalized contact with multiple unique numbers', () {
    final entries = parseDirectoryResponse({
      'contacts': [
        {
          'id': 'example-external-contact',
          'displayName': 'Example Contact',
          'company': 'Example Company',
          'type': 'external',
          'numbers': ['4165550101', '4165550102', '4165550101'],
        },
      ],
    });

    expect(entries, hasLength(1));
    expect(entries.single.numbers, ['4165550101', '4165550102']);
    expect(entries.single.hasMultipleNumbers, isTrue);
  });

  test('regroups external telephone rows into one contact', () {
    final entries = parseDirectoryResponse({
      'contacts': [
        {
          'id': 'example-company-4165550103',
          'displayName': 'Example Company',
          'company': 'Example Company',
          'type': 'external',
          'extension': '4165550103',
        },
        {
          'id': 'example-company-4165550104',
          'displayName': ' Example   Company ',
          'company': 'example company',
          'type': 'external',
          'extension': '4165550104',
        },
      ],
    });

    expect(entries, hasLength(1));
    expect(entries.single.displayName, 'Example Company');
    expect(entries.single.numbers, ['4165550103', '4165550104']);
  });

  test('regroups company rows and prefers the short PBX extension', () {
    final entries = parseDirectoryResponse({
      'contacts': [
        {
          'id': 'example-public',
          'displayName': 'Example Agent',
          'type': 'internal',
          'extension': '4165550105',
          'presence': 'unknown',
          'teams': ['Support', 'Fulfillment'],
        },
        {
          'id': 'example-extension',
          'displayName': 'Example Agent',
          'type': 'internal',
          'extension': '204',
          'presence': 'available',
          'teams': ['Support', 'Fulfillment'],
          'deviceRegistered': true,
        },
      ],
    });

    expect(entries, hasLength(1));
    expect(entries.single.numbers, ['204', '4165550105']);
    expect(entries.single.extension, '204');
    expect(entries.single.presence, DirectoryPresence.available);
    expect(entries.single.deviceRegistered, isTrue);
    expect(entries.single.teams, ['Support', 'Fulfillment']);
  });

  test('accepts the legacy singular team field', () {
    final entries = parseDirectoryResponse({
      'contacts': [
        {
          'displayName': 'Example Accountant',
          'type': 'internal',
          'extension': '108',
          'team': 'Example Accounting',
        },
      ],
    });

    expect(entries.single.teams, ['Example Accounting']);
  });

  test(
    'merges registration as reachable when any grouped row is reachable',
    () {
      final entries = parseDirectoryResponse({
        'contacts': [
          {
            'displayName': 'Support',
            'type': 'internal',
            'extension': '203',
            'deviceRegistered': false,
          },
          {
            'displayName': 'Support',
            'type': 'internal',
            'extension': '4165550203',
            'deviceRegistered': true,
          },
        ],
      });

      expect(entries.single.deviceRegistered, isTrue);
    },
  );

  test('does not merge matching names from different contact types', () {
    final entries = parseDirectoryResponse({
      'contacts': [
        {'displayName': 'Front Desk', 'type': 'internal', 'extension': '200'},
        {
          'displayName': 'Front Desk',
          'type': 'external',
          'extension': '4165550200',
        },
      ],
    });

    expect(entries, hasLength(2));
  });
}
