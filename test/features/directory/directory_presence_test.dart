import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/features/directory/data/directory_presence.dart';
import 'package:phone_app/features/directory/domain/directory_entry.dart';

void main() {
  DirectoryEntry entry(bool? registered) => DirectoryEntry(
    id: '105',
    displayName: 'Example User',
    numbers: const ['105'],
    telephoneKind: DirectoryTelephoneKind.internal,
    presence: DirectoryPresence.unknown,
    deviceRegistered: registered,
  );

  test('idle BLF is green only with a non-anchor device binding', () {
    expect(
      directoryPresenceWithRegistration(
        entry: entry(true),
        liveStates: const [DirectoryPresence.available],
      ),
      DirectoryPresence.available,
    );
    expect(
      directoryPresenceWithRegistration(
        entry: entry(false),
        liveStates: const [DirectoryPresence.available],
      ),
      DirectoryPresence.unregistered,
    );
  });

  test('missing registration metadata preserves the BLF idle state', () {
    expect(
      directoryPresenceWithRegistration(
        entry: entry(null),
        liveStates: const [DirectoryPresence.available],
      ),
      DirectoryPresence.available,
    );
  });

  test('ringing and busy remain authoritative', () {
    expect(
      directoryPresenceWithRegistration(
        entry: entry(false),
        liveStates: const [DirectoryPresence.ringing],
      ),
      DirectoryPresence.ringing,
    );
    expect(
      directoryPresenceWithRegistration(
        entry: entry(false),
        liveStates: const [DirectoryPresence.busy],
      ),
      DirectoryPresence.busy,
    );
  });

  test('PIDF reachability distinguishes idle from unavailable', () {
    expect(
      directoryPresenceWithRegistration(
        entry: entry(null),
        liveStates: const [DirectoryPresence.available],
        availabilityStates: const [DirectoryPresence.unregistered],
      ),
      DirectoryPresence.unregistered,
    );
    expect(
      directoryPresenceWithRegistration(
        entry: entry(null),
        liveStates: const [DirectoryPresence.available],
        availabilityStates: const [DirectoryPresence.available],
      ),
      DirectoryPresence.available,
    );
  });
}
