import '../domain/directory_entry.dart';

/// Whether directory ordering/search metadata is unchanged. BLF and freshness
/// are deliberately excluded: a status update must not re-sort the directory.
bool sameDirectoryContent(
  List<DirectoryEntry> previous,
  List<DirectoryEntry> next,
) {
  if (identical(previous, next)) return true;
  if (previous.length != next.length) return false;
  for (var i = 0; i < previous.length; i++) {
    final a = previous[i];
    final b = next[i];
    if (a.id != b.id ||
        a.displayName != b.displayName ||
        a.company != b.company ||
        a.telephoneKind != b.telephoneKind ||
        !_sameStrings(a.numbers, b.numbers) ||
        !_sameStrings(a.teams, b.teams)) {
      return false;
    }
  }
  return true;
}

/// Reuse a filtered/sorted projection while replacing entries with their latest
/// presence. Null means content changed and the caller must recompute ordering.
List<DirectoryEntry>? projectDirectoryPresenceUpdate({
  required List<DirectoryEntry> previousInput,
  required List<DirectoryEntry> input,
  required List<DirectoryEntry> previousVisible,
}) {
  if (!sameDirectoryContent(previousInput, input)) return null;
  final byId = {for (final entry in input) entry.id: entry};
  if (byId.length != input.length) return null;
  return [for (final entry in previousVisible) byId[entry.id]!];
}

bool _sameStrings(List<String> a, List<String> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
