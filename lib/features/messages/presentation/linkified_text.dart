import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

// shortcut: only http(s):// and www. links, no bare domains or emails; upgrade if users ask.
final _linkPattern = RegExp(
  r'(?:https?://|www\.)[^\s<>]+',
  caseSensitive: false,
);
const _trailingPunctuation = '.,;:!?)]}\'"';

typedef LinkOpener = Future<bool> Function(Uri uri);

/// Splits [text] into plain and link parts, trimming sentence punctuation that
/// trails a link. Each part is (text, uri) with a null uri for plain text.
List<(String, Uri?)> splitLinks(String text) {
  final parts = <(String, Uri?)>[];
  var cursor = 0;
  for (final match in _linkPattern.allMatches(text)) {
    var link = match.group(0)!;
    while (link.isNotEmpty &&
        _trailingPunctuation.contains(link[link.length - 1])) {
      link = link.substring(0, link.length - 1);
    }
    final uri = Uri.tryParse(
      link.toLowerCase().startsWith('www.') ? 'https://$link' : link,
    );
    if (uri == null || uri.host.isEmpty) continue;
    if (match.start > cursor) {
      parts.add((text.substring(cursor, match.start), null));
    }
    parts.add((link, uri));
    cursor = match.start + link.length;
  }
  if (cursor < text.length) parts.add((text.substring(cursor), null));
  return parts;
}

/// Message text whose links open in the phone's default app or browser
/// (e.g. Amazon links open the Amazon app when installed).
class LinkifiedText extends StatefulWidget {
  const LinkifiedText(
    this.text, {
    required this.style,
    this.openLink,
    super.key,
  });

  final String text;
  final TextStyle? style;
  final LinkOpener? openLink;

  @override
  State<LinkifiedText> createState() => _LinkifiedTextState();
}

class _LinkifiedTextState extends State<LinkifiedText> {
  final _recognizers = <TapGestureRecognizer>[];

  void _disposeRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  Future<void> _open(Uri uri) async {
    final opener =
        widget.openLink ??
        (Uri u) => launchUrl(u, mode: LaunchMode.externalApplication);
    var opened = false;
    try {
      opened = await opener(uri);
    } catch (_) {}
    if (!opened && widget.openLink == null) {
      try {
        opened = await launchUrl(uri);
      } catch (_) {}
    }
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open this link.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers();
    final linkStyle = (widget.style ?? const TextStyle()).copyWith(
      decoration: TextDecoration.underline,
      color: Theme.of(context).colorScheme.primary,
    );
    return Text.rich(
      TextSpan(
        style: widget.style,
        children: [
          for (final (text, uri) in splitLinks(widget.text))
            if (uri == null)
              TextSpan(text: text)
            else
              TextSpan(
                text: text,
                style: linkStyle,
                recognizer: _recognizerFor(uri),
              ),
        ],
      ),
    );
  }

  TapGestureRecognizer _recognizerFor(Uri uri) {
    final recognizer = TapGestureRecognizer()..onTap = () => _open(uri);
    _recognizers.add(recognizer);
    return recognizer;
  }
}
