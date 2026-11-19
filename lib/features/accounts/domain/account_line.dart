/// The app has exactly two lines. The first account activated is the primary
/// one; it keeps the original session and storage, so existing installs need
/// no migration.
enum AccountLine {
  primary,
  secondary;

  /// The id used on the native channel and in saved call records.
  String get wire => name;

  AccountLine get other =>
      this == AccountLine.primary ? AccountLine.secondary : AccountLine.primary;

  static AccountLine? tryParse(Object? value) {
    for (final line in values) {
      if (line.name == value) return line;
    }
    return null;
  }
}
