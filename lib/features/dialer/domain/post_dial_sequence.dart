class PostDialSequence {
  const PostDialSequence({required this.destination, required this.commands});

  final String destination;
  final String commands;

  bool get hasCommands => commands.isNotEmpty;

  static PostDialSequence parse(String raw) {
    final value = raw.trim();
    // A semicolon in a SIP URI starts URI parameters (for example,
    // `;transport=tcp`), not a telephone wait sequence. Post-dial notation is
    // supported for user-entered telephone numbers, which is also how mobile
    // contacts expose pause and wait digits.
    final normalized = value.toLowerCase();
    if (normalized.startsWith('sip:') || normalized.startsWith('sips:')) {
      return PostDialSequence(destination: value, commands: '');
    }
    final separator = value.indexOf(RegExp('[,;]'));
    if (separator < 0) {
      return PostDialSequence(destination: value, commands: '');
    }
    return PostDialSequence(
      destination: value.substring(0, separator).trim(),
      commands: value.substring(separator),
    );
  }
}
