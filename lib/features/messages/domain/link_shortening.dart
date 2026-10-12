/// Finds the links in an outgoing text message that are worth shortening.
///
/// Long links are the usual reason a text fails to send in parts, so only
/// links above [minLength] characters are returned. Punctuation that follows a
/// link in normal writing ("see https://x.example/a.") is not part of it.
List<String> linksToShorten(
  String text, {
  required int minLength,
  String? skipOrigin,
  int maxLinks = 5,
}) {
  final found = <String>{};
  for (final match in _urlPattern.allMatches(text)) {
    final link = _trimTrailing(match.group(0)!);
    if (link.length <= minLength) continue;
    if (skipOrigin != null && _hasOrigin(link, skipOrigin)) continue;
    found.add(link);
    if (found.length >= maxLinks) break;
  }
  return found.toList(growable: false);
}

/// Replaces each link with its short form, longest first so that one link
/// that contains another is never partly rewritten.
String replaceLinks(String text, Map<String, String> replacements) {
  final originals = replacements.keys.toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  var result = text;
  for (final original in originals) {
    result = result.replaceAll(original, replacements[original]!);
  }
  return result;
}

final _urlPattern = RegExp(
  r'https?://[^\s<>"\u0000-\u001f]+',
  caseSensitive: false,
);

const _closers = {')': '(', ']': '[', '}': '{'};

String _trimTrailing(String link) {
  var end = link.length;
  while (end > 0) {
    final last = link[end - 1];
    if ('.,;:!?\'"'.contains(last)) {
      end--;
      continue;
    }
    final opener = _closers[last];
    if (opener != null) {
      final inside = link.substring(0, end);
      final opens = opener.allMatches(inside).length;
      final closes = last.allMatches(inside).length;
      if (closes > opens) {
        end--;
        continue;
      }
    }
    break;
  }
  return link.substring(0, end);
}

bool _hasOrigin(String link, String origin) {
  final uri = Uri.tryParse(link);
  final base = Uri.tryParse(origin);
  if (uri == null || base == null) return false;
  return uri.host.toLowerCase() == base.host.toLowerCase();
}
