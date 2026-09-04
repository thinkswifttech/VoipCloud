import 'package:xml/xml.dart';

import '../domain/directory_entry.dart';

List<DirectoryEntry> parseYealinkDirectoryXml(String body) {
  final document = XmlDocument.parse(body);
  final entries = <DirectoryEntry>[];
  var index = 0;

  for (final node in document.findAllElements('DirectoryEntry')) {
    final name = node.getElement('Name')?.innerText.trim() ?? '';
    final telephones = node
        .findElements('Telephone')
        .map((telephone) => telephone.innerText.trim())
        .where((number) => number.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (name.isEmpty || telephones.isEmpty) {
      continue;
    }

    final type =
        node.getElement('Telephone')?.getAttribute('type')?.trim() ??
        node.getElement('value')?.innerText.trim() ??
        '';
    final kind = switch (type.toLowerCase()) {
      'internal' => DirectoryTelephoneKind.internal,
      'external' => DirectoryTelephoneKind.external,
      _ => DirectoryTelephoneKind.unknown,
    };
    final company = node.getElement('Company')?.innerText.trim() ?? '';
    final seenTeams = <String>{};
    final teams = node.children
        .whereType<XmlElement>()
        .where((element) {
          final name = element.name.local.toLowerCase();
          return name == 'team' || name == 'teams';
        })
        .map((element) => element.innerText.trim())
        .where((team) => team.isNotEmpty && seenTeams.add(team.toLowerCase()))
        .toList(growable: false);

    entries.add(
      DirectoryEntry(
        id: 'dir-${telephones.join('-')}-$index',
        displayName: name,
        numbers: telephones,
        company: company,
        teams: teams,
        telephoneKind: kind,
        presence: DirectoryPresence.unknown,
      ),
    );
    index += 1;
  }

  return entries;
}
