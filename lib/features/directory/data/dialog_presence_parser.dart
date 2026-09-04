import 'package:xml/xml.dart';

import '../domain/directory_entry.dart';

enum SipPresencePackage { dialog, presence }

class SipPresenceUpdate {
  const SipPresenceUpdate({required this.package, required this.presence});

  final SipPresencePackage package;
  final DirectoryPresence presence;
}

SipPresenceUpdate? parseSipPresenceEvent(Map<String, dynamic> event) {
  final package = '${event['event'] ?? 'dialog'}'.trim().toLowerCase();
  if (package == 'presence') {
    final presence = parsePidfPresenceEvent(event);
    return presence == null
        ? null
        : SipPresenceUpdate(
            package: SipPresencePackage.presence,
            presence: presence,
          );
  }
  final presence = parseDialogPresenceEvent(event);
  return presence == null
      ? null
      : SipPresenceUpdate(
          package: SipPresencePackage.dialog,
          presence: presence,
        );
}

DirectoryPresence? parseDialogPresenceEvent(Map<String, dynamic> event) {
  final kind = '${event['kind'] ?? 'notify'}'.toLowerCase();
  if (kind == 'subscription') {
    return switch ('${event['state'] ?? ''}'.toLowerCase()) {
      'error' => DirectoryPresence.unknown,
      'terminated' => DirectoryPresence.unknown,
      _ => null,
    };
  }

  final body = '${event['body'] ?? ''}'.trim();
  if (body.isEmpty) return null;

  final XmlDocument document;
  try {
    document = XmlDocument.parse(body);
  } on XmlParserException {
    return null;
  }

  final states = document.descendants
      .whereType<XmlElement>()
      .where((element) => element.name.local.toLowerCase() == 'state')
      .map((element) => element.innerText.trim().toLowerCase())
      .where((state) => state.isNotEmpty)
      .toSet();

  if (states.any(_isRingingState)) return DirectoryPresence.ringing;
  if (states.any(_isBusyState)) return DirectoryPresence.busy;
  if (states.isEmpty || states.every(_isAvailableState)) {
    return DirectoryPresence.available;
  }
  return DirectoryPresence.unknown;
}

bool _isRingingState(String state) =>
    const {'early', 'proceeding', 'trying'}.contains(state);

bool _isBusyState(String state) => const {'confirmed'}.contains(state);

bool _isAvailableState(String state) => const {'terminated'}.contains(state);

DirectoryPresence? parsePidfPresenceEvent(Map<String, dynamic> event) {
  final kind = '${event['kind'] ?? 'notify'}'.toLowerCase();
  if (kind == 'subscription') {
    return switch ('${event['state'] ?? ''}'.toLowerCase()) {
      'error' || 'terminated' => DirectoryPresence.unknown,
      _ => null,
    };
  }

  final body = '${event['body'] ?? ''}'.trim();
  if (body.isEmpty) return null;

  final XmlDocument document;
  try {
    document = XmlDocument.parse(body);
  } on XmlParserException {
    return null;
  }

  final basicStates = document.descendants
      .whereType<XmlElement>()
      .where((element) => element.name.local.toLowerCase() == 'basic')
      .map((element) => element.innerText.trim().toLowerCase())
      .where((state) => state.isNotEmpty)
      .toSet();

  if (basicStates.contains('open')) return DirectoryPresence.available;
  if (basicStates.isNotEmpty &&
      basicStates.every((state) => state == 'closed')) {
    return DirectoryPresence.unregistered;
  }
  return DirectoryPresence.unknown;
}
