import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/features/contacts/domain/quick_dial_entry.dart';
import 'package:phone_app/features/contacts/domain/quick_dial_presence.dart';
import 'package:phone_app/features/contacts/domain/quick_dial_csv.dart';
import 'package:phone_app/features/directory/domain/directory_entry.dart';

QuickDialEntry quick({
  bool? showBlf,
  QuickDialSource source = QuickDialSource.custom,
  String number = '210',
}) => QuickDialEntry(
  id: 'qd',
  displayName: 'Test',
  number: number,
  source: source,
  createdAt: DateTime(2026),
  showBlf: showBlf,
);

DirectoryEntry company(
  DirectoryPresence presence, {
  String number = '210',
  bool external = false,
}) => DirectoryEntry(
  id: number,
  displayName: 'Directory Test',
  numbers: [number],
  telephoneKind: external
      ? DirectoryTelephoneKind.external
      : DirectoryTelephoneKind.internal,
  presence: presence,
);

void main() {
  test(
    'directory additions default to BLF, manual and phone contacts do not',
    () {
      expect(quick(source: QuickDialSource.directory).showBlf, true);
      expect(quick().showBlf, false);
      expect(quick(source: QuickDialSource.contact).showBlf, false);
    },
  );
  test('legacy JSON migrates by source, explicit visibility always wins', () {
    for (final source in QuickDialSource.values) {
      final json = quick(source: source).toJson()..remove('showBlf');
      expect(
        QuickDialEntry.fromJson(json).showBlf,
        source == QuickDialSource.directory,
      );
      json['showBlf'] = false;
      expect(QuickDialEntry.fromJson(json).showBlf, false);
    }
  });
  test('hidden BLF stays hidden even for an available company match', () {
    expect(
      quickDialPresence(quick(showBlf: false), [
        company(DirectoryPresence.available),
      ]),
      isNull,
    );
  });
  test('enabled manual directory matches use every live state', () {
    for (final presence in DirectoryPresence.values) {
      expect(
        quickDialPresence(quick(showBlf: true), [company(presence)]),
        presence,
      );
    }
  });
  test(
    'unknown and external numbers stay unknown, never invent availability',
    () {
      expect(
        quickDialPresence(quick(showBlf: true), []),
        DirectoryPresence.unknown,
      );
      expect(
        quickDialPresence(quick(showBlf: true), [
          company(DirectoryPresence.available, external: true),
        ]),
        DirectoryPresence.unknown,
      );
      expect(
        quickDialPresence(quick(showBlf: true, number: '999'), [
          company(DirectoryPresence.available),
        ]),
        DirectoryPresence.unknown,
      );
    },
  );
  test(
    'safe telephone formatting matches without conflating SIP domains or pauses',
    () {
      expect(
        quickDialPresence(quick(showBlf: true, number: '(210)'), [
          company(DirectoryPresence.busy),
        ]),
        DirectoryPresence.busy,
      );
      for (final number in [
        'sip:210@other.example',
        '210,123',
        '210;123',
        '2100',
      ]) {
        expect(
          quickDialPresence(quick(showBlf: true, number: number), [
            company(DirectoryPresence.available),
          ]),
          DirectoryPresence.unknown,
        );
      }
    },
  );
  test('matches secondary directory numbers', () {
    final entry = DirectoryEntry(
      id: 'x',
      displayName: 'Multi',
      numbers: const ['209', '210'],
      telephoneKind: DirectoryTelephoneKind.internal,
      presence: DirectoryPresence.ringing,
    );
    expect(
      quickDialPresence(quick(showBlf: true), [entry]),
      DirectoryPresence.ringing,
    );
  });
  test('direct PBX states work without directory membership', () {
    for (final state in DirectoryPresence.values) {
      expect(
        quickDialPresence(
          quick(showBlf: true),
          [],
          directStates: {'210': state},
        ),
        state,
      );
    }
    expect(
      quickDialPresence(
        quick(showBlf: false),
        [],
        directStates: {'210': DirectoryPresence.busy},
      ),
      isNull,
    );
  });
  test('probe only enabled plain internal extensions, deduplicated', () {
    final entries = quickDialBlfEntries([
      quick(showBlf: true),
      quick(showBlf: true, number: '(210)'),
      quick(showBlf: false, number: '211'),
      for (final number in [
        '+14165551234',
        '4165551234',
        'sip:210@other.example',
        '210,1',
        '210;1',
        '*76',
      ])
        quick(showBlf: true, number: number),
    ]);
    expect(entries.map((e) => e.extension), ['210']);
    expect(entries.single.presence, DirectoryPresence.unknown);
  });
  test('copy and JSON keep false even for directory entries', () {
    final entry = quick(
      source: QuickDialSource.directory,
    ).copyWith(showBlf: false);
    expect(entry.copyWith(displayName: 'Renamed').showBlf, false);
    expect(QuickDialEntry.fromJson(entry.toJson()).showBlf, false);
  });
  test('CSV preserves preferences and migrates legacy directory rows', () {
    final decoded = QuickDialCsvCodec.decode(
      QuickDialCsvCodec.encode([
        quick(showBlf: true),
        quick(source: QuickDialSource.directory, showBlf: false),
      ]),
    );
    expect(decoded.map((e) => e.showBlf), [true, false]);
    expect(
      QuickDialCsvCodec.decode(
        'displayName,number,source,sourceId\nTest,210,directory,210\n',
      ).single.showBlf,
      true,
    );
  });
}
