import '../../directory/domain/directory_access.dart';
import '../../messages/domain/carrier_messaging_config.dart';
import '../../session/domain/device_credential.dart';
import '../../sip/domain/sip_config.dart';
import 'account_line.dart';

export 'account_line.dart';

/// What the Call button does when two lines exist and nothing else decides.
enum DefaultOutgoingLine {
  ask,
  primary,
  secondary;

  static DefaultOutgoingLine parse(Object? value) {
    for (final option in values) {
      if (option.name == value) return option;
    }
    return DefaultOutgoingLine.ask;
  }

  AccountLine? get line => switch (this) {
    DefaultOutgoingLine.ask => null,
    DefaultOutgoingLine.primary => AccountLine.primary,
    DefaultOutgoingLine.secondary => AccountLine.secondary,
  };
}

/// Colours offered for a line (ARGB): a restrained set that never reads as
/// error (red), success (green) or warning (amber). The first is the primary
/// account's default, the second the second account's default.
const accountColorChoices = <int>[
  0xFF2B5FD9, // blue
  0xFF0F766E, // teal
  0xFF6D4AC7, // violet
  0xFFA23B72, // plum
  0xFF475569, // slate
  0xFF9A4F1E, // copper
];

/// User-chosen name and colour of one line. `null` means "use the default".
class AccountAppearance {
  const AccountAppearance({this.label, this.colorValue});

  factory AccountAppearance.fromJson(Object? json) {
    if (json is! Map) return const AccountAppearance();
    final label = json['label'];
    final color = json['color'];
    return AccountAppearance(
      label: label is String && label.trim().isNotEmpty ? label.trim() : null,
      colorValue: color is int ? color : null,
    );
  }

  final String? label;
  final int? colorValue;

  /// An empty [label] resets the name to the default.
  AccountAppearance copyWith({String? label, int? colorValue}) {
    return AccountAppearance(
      label: label == null
          ? this.label
          : (label.trim().isEmpty ? null : label.trim()),
      colorValue: colorValue ?? this.colorValue,
    );
  }

  Map<String, Object?> toJson() => {'label': label, 'color': colorValue};
}

/// Settings that belong to the pair of lines, not to a single account.
class AccountsPrefs {
  const AccountsPrefs({
    this.primary = const AccountAppearance(),
    this.secondary = const AccountAppearance(),
    this.defaultOutgoing = DefaultOutgoingLine.ask,
  });

  factory AccountsPrefs.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const AccountsPrefs();
    return AccountsPrefs(
      primary: AccountAppearance.fromJson(json['primary']),
      secondary: AccountAppearance.fromJson(json['secondary']),
      defaultOutgoing: DefaultOutgoingLine.parse(json['defaultOutgoing']),
    );
  }

  final AccountAppearance primary;
  final AccountAppearance secondary;
  final DefaultOutgoingLine defaultOutgoing;

  AccountAppearance appearance(AccountLine line) =>
      line == AccountLine.primary ? primary : secondary;

  AccountsPrefs withAppearance(AccountLine line, AccountAppearance value) {
    return AccountsPrefs(
      primary: line == AccountLine.primary ? value : primary,
      secondary: line == AccountLine.secondary ? value : secondary,
      defaultOutgoing: defaultOutgoing,
    );
  }

  AccountsPrefs withDefaultOutgoing(DefaultOutgoingLine value) {
    return AccountsPrefs(
      primary: primary,
      secondary: secondary,
      defaultOutgoing: value,
    );
  }

  /// The line's own colour, or its default.
  int colorValue(AccountLine line) =>
      appearance(line).colorValue ??
      accountColorChoices[line == AccountLine.primary ? 0 : 1];

  /// The line's own name, or "210 · swift" derived from the account.
  String label(AccountLine line, SipConfig? config) {
    final custom = appearance(line).label;
    if (custom != null) return custom;
    return defaultLineLabel(config) ??
        (line == AccountLine.primary ? 'Primary line' : 'Second line');
  }

  Map<String, Object?> toJson() => {
    'primary': primary.toJson(),
    'secondary': secondary.toJson(),
    'defaultOutgoing': defaultOutgoing.name,
  };
}

/// "210 · swift" for extension 210 on swift.example.test.
String? defaultLineLabel(SipConfig? config) {
  if (config == null) return null;
  final extension = config.extension.trim().isEmpty
      ? config.sipUsername.trim()
      : config.extension.trim();
  if (extension.isEmpty) return null;
  final host = config.domain.split('.').first.trim();
  return host.isEmpty ? extension : '$extension · $host';
}

/// Everything provisioned for the second line. Only the calling part is used
/// today; the rest is kept for per-account directory and messaging later.
class SecondaryAccount {
  const SecondaryAccount({
    required this.sipConfig,
    this.directoryAccess,
    this.deviceCredential,
    this.carrierMessaging,
  });

  factory SecondaryAccount.fromJson(Map<String, dynamic> json) {
    Map<String, dynamic>? map(Object? value) =>
        value is Map ? Map<String, dynamic>.from(value) : null;
    final sip = map(json['sip']);
    if (sip == null) {
      throw const FormatException('Second account has no calling settings');
    }
    final directory = map(json['directory']);
    final credential = map(json['deviceCredential']);
    final messaging = map(json['carrierMessaging']);
    return SecondaryAccount(
      sipConfig: SipConfig.fromJson(sip),
      directoryAccess: directory == null
          ? null
          : DirectoryAccess.fromJson(directory),
      deviceCredential: credential == null
          ? null
          : DeviceCredential.fromJson(credential),
      carrierMessaging: messaging == null
          ? null
          : CarrierMessagingConfig.fromJson(messaging),
    );
  }

  final SipConfig sipConfig;
  final DirectoryAccess? directoryAccess;
  final DeviceCredential? deviceCredential;
  final CarrierMessagingConfig? carrierMessaging;

  SecondaryAccount withSipConfig(SipConfig config) => SecondaryAccount(
    sipConfig: config,
    directoryAccess: directoryAccess,
    deviceCredential: deviceCredential,
    carrierMessaging: carrierMessaging,
  );

  Map<String, Object?> toJson() => {
    'sip': sipConfig.toJson(),
    'directory': directoryAccess?.toJson(),
    'deviceCredential': deviceCredential?.toJson(),
    'carrierMessaging': carrierMessaging?.toJson(),
  };
}
