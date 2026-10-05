import '../../directory/domain/directory_entry.dart';
import 'quick_dial_entry.dart';

/// Only plain internal extensions are probed in the signed-in SIP domain.
/// Phone numbers, SIP URIs, feature codes and post-dial sequences are not probes.
String? quickDialBlfTarget(QuickDialEntry entry) {
  if (!entry.showBlf) return null;
  final number = _normalized(entry.number);
  return RegExp(r'^\d{2,8}$').hasMatch(number) ? number : null;
}

List<DirectoryEntry> quickDialBlfEntries(Iterable<QuickDialEntry> entries) => [
  for (final number
      in entries.map(quickDialBlfTarget).whereType<String>().toSet())
    DirectoryEntry(
      id: 'quick-dial-blf:$number',
      displayName: number,
      numbers: [number],
      telephoneKind: DirectoryTelephoneKind.internal,
      presence: DirectoryPresence.unknown,
    ),
];

DirectoryPresence? quickDialPresence(
  QuickDialEntry entry,
  Iterable<DirectoryEntry> directory, {
  Map<String, DirectoryPresence> directStates = const {},
}) {
  if (!entry.showBlf) return null;
  final number = _normalized(entry.number);
  if (number.isEmpty) return DirectoryPresence.unknown;
  for (final candidate in directory) {
    if (candidate.isCompany &&
        candidate.numbers.any((value) => _normalized(value) == number)) {
      return candidate.presence;
    }
  }
  final target = quickDialBlfTarget(entry);
  return directStates[target] ?? DirectoryPresence.unknown;
}

String _normalized(String value) {
  final text = value.trim();
  if (!RegExp(r'^\+?[0-9\s()-]+$').hasMatch(text)) return '';
  return text.replaceAll(RegExp(r'[\s()-]'), '');
}
