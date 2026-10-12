import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/features/directory/data/directory_presentation_projection.dart';
import 'package:phone_app/features/directory/domain/directory_entry.dart';

DirectoryEntry entry(
  String id, {
  String? name,
  List<String>? numbers,
  List<String> teams = const [],
}) => DirectoryEntry(
  id: id,
  displayName: name ?? id,
  numbers: numbers ?? [id],
  teams: teams,
  telephoneKind: DirectoryTelephoneKind.internal,
  presence: DirectoryPresence.unknown,
);

void main() {
  test(
    'BLF-only updates reuse filtered order with latest status and freshness',
    () {
      final previous = [entry('210'), entry('211'), entry('212')];
      final next = [
        for (final e in previous)
          e.copyWith(
            presence: DirectoryPresence.busy,
            presenceFreshness: DirectoryPresenceFreshness.live,
          ),
      ];
      final projected = projectDirectoryPresenceUpdate(
        previousInput: previous,
        input: next,
        previousVisible: [previous[2], previous[0]],
      );
      expect(projected!.map((e) => e.id), ['212', '210']);
      expect(
        projected.every((e) => e.presence == DirectoryPresence.busy),
        isTrue,
      );
      expect(
        projected.first.presenceFreshness,
        DirectoryPresenceFreshness.live,
      );
      expect(identical(projected.first, next[2]), isTrue);
    },
  );
  test(
    'renames, number changes, team changes and added entries invalidate ordering',
    () {
      final previous = [entry('210')];
      for (final next in [
        [entry('210', name: 'New name')],
        [
          entry('210', numbers: ['211']),
        ],
        [
          entry('210', teams: ['Support']),
        ],
        [entry('210'), entry('211')],
        <DirectoryEntry>[],
      ]) {
        expect(
          projectDirectoryPresenceUpdate(
            previousInput: previous,
            input: next,
            previousVisible: previous,
          ),
          isNull,
        );
      }
    },
  );
  test('duplicate ids never project another row into a contact', () {
    final previous = [entry('210'), entry('210')];
    expect(
      projectDirectoryPresenceUpdate(
        previousInput: previous,
        input: previous,
        previousVisible: previous,
      ),
      isNull,
    );
  });
}
