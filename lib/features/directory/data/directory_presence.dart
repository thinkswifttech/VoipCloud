import '../domain/directory_entry.dart';

DirectoryPresence directoryPresenceWithRegistration({
  required DirectoryEntry entry,
  required Iterable<DirectoryPresence> liveStates,
  Iterable<DirectoryPresence> availabilityStates = const [],
}) {
  final states = liveStates.toList(growable: false);
  if (states.contains(DirectoryPresence.ringing)) {
    return DirectoryPresence.ringing;
  }
  if (states.contains(DirectoryPresence.busy)) {
    return DirectoryPresence.busy;
  }

  final reachability = availabilityStates.toList(growable: false);
  if (reachability.contains(DirectoryPresence.available)) {
    return DirectoryPresence.available;
  }
  if (reachability.isNotEmpty &&
      reachability.every(
        (state) =>
            state == DirectoryPresence.unregistered ||
            state == DirectoryPresence.unknown,
      ) &&
      reachability.contains(DirectoryPresence.unregistered)) {
    return DirectoryPresence.unregistered;
  }

  if (states.isEmpty) return entry.presence;
  if (states.contains(DirectoryPresence.available)) {
    return switch (entry.deviceRegistered) {
      true => DirectoryPresence.available,
      false => DirectoryPresence.unregistered,
      // Older directory gateways do not expose registration metadata yet.
      // Preserve the BLF result until that optional signal is available.
      null => DirectoryPresence.available,
    };
  }
  if (states.every((state) => state == DirectoryPresence.unregistered)) {
    return DirectoryPresence.unregistered;
  }
  return DirectoryPresence.unknown;
}
