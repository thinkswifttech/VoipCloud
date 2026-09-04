import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/features/contacts/domain/quick_dial_csv.dart';
import 'package:phone_app/features/contacts/domain/quick_dial_entry.dart';

void main() {
  test('encodes and decodes quick dial CSV round-trip including photos', () {
    final photo = Uint8List.fromList([1, 2, 3, 4, 5]);
    final entries = [
      QuickDialEntry(
        id: 'qd-1',
        displayName: 'Ada Lovelace',
        number: '+15551212',
        source: QuickDialSource.contact,
        sourceId: 'c-1',
        photoBytes: photo,
        createdAt: DateTime(2026, 1, 1),
      ),
      QuickDialEntry(
        id: 'qd-2',
        displayName: 'Ops, Inc',
        number: '1001',
        source: QuickDialSource.directory,
        sourceId: 'd-2',
        createdAt: DateTime(2026, 1, 2),
      ),
    ];

    final csv = QuickDialCsvCodec.encode(entries);
    expect(csv, contains('photoBase64'));
    expect(csv, contains(base64Encode(photo)));

    final decoded = QuickDialCsvCodec.decode(csv);

    expect(decoded, hasLength(2));
    expect(decoded[0].displayName, 'Ada Lovelace');
    expect(decoded[0].number, '+15551212');
    expect(decoded[0].source, QuickDialSource.contact);
    expect(decoded[0].sourceId, 'c-1');
    expect(decoded[0].photoBytes, photo);
    expect(decoded[1].displayName, 'Ops, Inc');
    expect(decoded[1].number, '1001');
    expect(decoded[1].source, QuickDialSource.directory);
    expect(decoded[1].photoBytes, isNull);
  });

  test('still imports older CSV rows without a photo column', () {
    const legacy =
        'displayName,number,source,sourceId\n'
        'Ada Lovelace,+15551212,contact,c-1\n';
    final decoded = QuickDialCsvCodec.decode(legacy);
    expect(decoded, hasLength(1));
    expect(decoded.first.photoBytes, isNull);
    expect(decoded.first.sourceId, 'c-1');
  });
}
