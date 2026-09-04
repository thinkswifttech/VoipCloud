import 'dart:typed_data';

import '../../contacts/domain/contact.dart';
import '../../directory/domain/directory_entry.dart';
import '../domain/voip_call.dart';

class CallerIdentity {
  const CallerIdentity({
    required this.label,
    required this.number,
    this.isResolvedName = false,
    this.photo,
  });

  /// Contact/directory display name when known, otherwise the dialable number.
  final String label;

  /// Normalized number/extension extracted from the remote identity.
  final String number;

  final bool isResolvedName;
  final Uint8List? photo;

  String get initials {
    if (!isResolvedName) {
      return '';
    }
    final parts = label
        .trim()
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .toList();
    if (parts.isEmpty) {
      return '';
    }
    if (parts.length == 1) {
      return parts.first[0].toUpperCase();
    }
    return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
  }
}

/// Prefer device contact name, then directory display name, then SIP display
/// name (when it isn't just the number), then the number itself.
CallerIdentity resolveCallerIdentity({
  required VoipCall? call,
  required List<Contact> contacts,
  required List<DirectoryEntry> directory,
}) {
  return resolveRemoteIdentity(
    remoteUri: call?.remoteUri ?? '',
    remoteDisplayName: call?.remoteDisplayName,
    contacts: contacts,
    directory: directory,
  );
}

CallerIdentity resolveRemoteIdentity({
  required String remoteUri,
  String? remoteDisplayName,
  required List<Contact> contacts,
  required List<DirectoryEntry> directory,
}) {
  final remoteDisplay = remoteDisplayName?.trim() ?? '';
  final number = _identityNumber(
    remoteUri.isNotEmpty ? remoteUri : remoteDisplay,
  );

  if (number.isNotEmpty) {
    for (final contact in contacts) {
      if (_contactMatches(contact, number)) {
        final name = contact.displayName.trim();
        if (name.isNotEmpty) {
          return CallerIdentity(
            label: _withQueuePrefix(
              name,
              number,
              sourceDisplayName: remoteDisplay,
            ),
            number: number,
            isResolvedName: true,
            photo: contact.photo,
          );
        }
        if (contact.photo != null) {
          return CallerIdentity(
            label: number,
            number: number,
            photo: contact.photo,
          );
        }
      }
    }

    for (final entry in directory) {
      final matchesDirectoryNumber = entry.numbers.any((candidate) {
        final normalized = _identityNumber(candidate);
        return normalized.isNotEmpty && _numbersMatch(number, normalized);
      });
      if (matchesDirectoryNumber) {
        final name = entry.displayName.trim();
        if (name.isNotEmpty) {
          return CallerIdentity(
            label: _withQueuePrefix(
              name,
              number,
              sourceDisplayName: remoteDisplay,
            ),
            number: number,
            isResolvedName: true,
          );
        }
      }
    }
  }

  if (remoteDisplay.isNotEmpty && !_looksLikeNumberOnly(remoteDisplay)) {
    return CallerIdentity(
      label: _withQueuePrefix(
        remoteDisplay,
        number,
        sourceDisplayName: remoteDisplay,
      ),
      number: number.isNotEmpty ? number : _displayUri(remoteDisplay),
      isResolvedName: true,
    );
  }

  final fallback = number.isNotEmpty
      ? number
      : _displayUri(remoteUri.isNotEmpty ? remoteUri : remoteDisplay);
  return CallerIdentity(
    label: fallback.isEmpty ? 'Unknown' : fallback,
    number: number,
  );
}

/// PBXs commonly encode the queue that delivered a call in the SIP user
/// (`sales:14165550123`). Contact and directory resolution must enrich the
/// caller identity without discarding that operational context.
String _withQueuePrefix(
  String label,
  String number, {
  String? sourceDisplayName,
}) {
  final dialPrefix = _dialPrefix(number);
  final prefix = dialPrefix ?? _displayNamePrefix(sourceDisplayName);
  final trimmed = label.trim();
  if (prefix == null || trimmed.isEmpty) {
    return trimmed;
  }
  final prefixMarker = '$prefix:';
  if (trimmed.toLowerCase().startsWith(prefixMarker.toLowerCase())) {
    return trimmed;
  }
  final suffix = dialPrefix == null ? '' : number.substring(prefix.length + 1);
  if (suffix.isNotEmpty &&
      _identityNumber(trimmed) == _identityNumber(suffix)) {
    return number;
  }
  return '$prefix: $trimmed';
}

String? _displayNamePrefix(String? value) {
  final match = RegExp(
    r'^([A-Za-z][A-Za-z0-9._ -]{0,31}):\s*.+$',
  ).firstMatch(value?.trim() ?? '');
  return match?.group(1)?.trim();
}

String? _dialPrefix(String value) {
  final compact = value.trim();
  if (!_prefixedDialIdentifier.hasMatch(compact)) {
    return null;
  }
  final separator = compact.indexOf(':');
  return separator > 0 ? compact.substring(0, separator) : null;
}

bool _contactMatches(Contact contact, String number) {
  final candidates = <String>{
    _identityNumber(contact.phoneNumber),
    _identityNumber(contact.extension),
    for (final phone in contact.dialablePhones) _identityNumber(phone.number),
  }..removeWhere((value) => value.isEmpty);

  final primary = _identityNumber(contact.phoneNumber);
  final extension = _identityNumber(contact.extension);
  if (primary.isNotEmpty && extension.isNotEmpty) {
    candidates.add('$primary,$extension');
  }

  return candidates.any((candidate) => _numbersMatch(number, candidate));
}

bool _numbersMatch(String left, String right) {
  if (left == right) {
    return true;
  }
  final leftDigits = left.replaceAll(RegExp(r'\D'), '');
  final rightDigits = right.replaceAll(RegExp(r'\D'), '');
  if (leftDigits.isEmpty || rightDigits.isEmpty) {
    return false;
  }
  if (leftDigits == rightDigits) {
    return true;
  }
  // Match NANP last-10 when one side includes country code.
  if (leftDigits.length >= 10 && rightDigits.length >= 10) {
    return leftDigits.substring(leftDigits.length - 10) ==
        rightDigits.substring(rightDigits.length - 10);
  }
  return false;
}

bool _looksLikeNumberOnly(String value) {
  final normalized = _identityNumber(value);
  if (normalized.isEmpty) {
    return false;
  }
  final stripped = value
      .replaceFirst(RegExp(r'^(sip:|sips:)', caseSensitive: false), '')
      .split('@')
      .first
      .trim();
  return _identityNumber(stripped) == normalized &&
      !RegExp(r'[A-Za-z]').hasMatch(stripped);
}

String _identityNumber(String? value) {
  var text = value?.trim() ?? '';
  if (text.isEmpty) {
    return '';
  }

  final lower = text.toLowerCase();
  final sipsIndex = lower.indexOf('sips:');
  final sipIndex = lower.indexOf('sip:');
  final isSipIdentity = sipsIndex >= 0 || sipIndex >= 0;
  if (sipsIndex >= 0) {
    text = text.substring(sipsIndex + 5);
  } else if (sipIndex >= 0) {
    text = text.substring(sipIndex + 4);
  }

  text = text
      .replaceAll('<', '')
      .replaceAll('>', '')
      .replaceAll('"', '')
      .split(';')
      .first
      .split('?')
      .first
      .trim();
  if (text.contains('@')) {
    text = text.split('@').first.trim();
  }

  try {
    text = Uri.decodeComponent(text);
  } on ArgumentError {
    // Bare "%" / incomplete %XX from SIP URIs — keep raw text.
  } on FormatException {
    // Keep malformed remote identifiers best-effort.
  }

  final compact = text.replaceAll(RegExp(r'\s+'), '');
  if (_prefixedDialIdentifier.hasMatch(compact)) {
    return compact;
  }

  final allowed = RegExp(r'[0-9+*#,]');
  final numeric = compact
      .split('')
      .where((char) => allowed.hasMatch(char))
      .join();
  if (numeric.isNotEmpty) {
    return numeric;
  }

  // Preserve valid non-numeric SIP users, but do not treat arbitrary display
  // names as dialable identities.
  if (isSipIdentity && _sipUserIdentifier.hasMatch(compact)) {
    return compact;
  }
  return '';
}

final _prefixedDialIdentifier = RegExp(
  r'^[A-Za-z][A-Za-z0-9._-]*:[+*#0-9][A-Za-z0-9+*#,._-]*$',
);

final _sipUserIdentifier = RegExp(r'^[A-Za-z0-9+*#,._-]+$');

String _displayUri(String value) {
  return value
      .replaceFirst(RegExp(r'^(sip:|sips:)', caseSensitive: false), '')
      .split(';')
      .first
      .trim();
}
