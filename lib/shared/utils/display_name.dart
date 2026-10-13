/// Directory and PBX names often carry a short tag before the person's name,
/// such as `SUP: Leo Grosso` or `SUP:SAHIL MILLU`. The tag is useful in lists
/// but must not become the initials, so initials are built from the part after
/// it. Returns [name] unchanged when there is no such tag.
String nameWithoutPrefixTag(String name) {
  final trimmed = name.trim();
  final colon = trimmed.indexOf(':');
  if (colon < 1 || colon > 12 || colon == trimmed.length - 1) return trimmed;
  final tag = trimmed.substring(0, colon);
  if (tag.contains(RegExp(r'\s'))) return trimmed;
  // Not a name tag: URI schemes such as sip:101@host.
  if (const {'sip', 'sips', 'tel'}.contains(tag.toLowerCase())) return trimmed;
  final rest = trimmed.substring(colon + 1).trim();
  return rest.isEmpty ? trimmed : rest;
}
