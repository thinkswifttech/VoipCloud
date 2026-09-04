enum DirectoryPresence {
  /// Extension is registered and free to take calls.
  available,

  /// Extension is registered but currently in a call.
  busy,

  /// Extension is currently receiving an incoming call.
  ringing,

  /// Extension has not registered with the PBX.
  unregistered,

  /// The directory source does not expose live registration state.
  unknown,
}

enum DirectoryTelephoneKind { internal, external, unknown }

class DirectoryEntry {
  const DirectoryEntry({
    required this.id,
    required this.displayName,
    required this.numbers,
    required this.telephoneKind,
    required this.presence,
    this.company = '',
    this.teams = const [],
    this.deviceRegistered,
  }) : assert(numbers.length > 0);

  final String id;
  final String displayName;
  final List<String> numbers;
  final String company;
  final List<String> teams;
  final DirectoryTelephoneKind telephoneKind;
  final DirectoryPresence presence;

  /// Whether Flexisip has a reachable, non-anchor device binding.
  ///
  /// `null` means the directory gateway did not provide registration state.
  /// The persistent B2BUA anchor must never set this value to true.
  final bool? deviceRegistered;

  factory DirectoryEntry.fromJson(Map<String, dynamic> json) {
    final numbers = _numbers(json);
    final displayName = '${json['displayName'] ?? json['name'] ?? ''}'.trim();
    if (numbers.isEmpty || displayName.isEmpty) {
      throw const FormatException('Invalid directory entry');
    }
    return DirectoryEntry(
      id: '${json['id'] ?? numbers.first}'.trim(),
      displayName: displayName,
      numbers: numbers,
      company: '${json['company'] ?? ''}'.trim(),
      teams: _stringList(json['teams'] ?? json['team']),
      telephoneKind: _telephoneKind(json['type'] ?? json['telephoneKind']),
      presence: directoryPresenceFromValue(json['presence']),
      deviceRegistered: _optionalBool(
        json['deviceRegistered'] ?? json['device_registered'],
      ),
    );
  }

  /// Backward-compatible primary dial target for single-number consumers.
  String get extension => numbers.first;

  bool get hasMultipleNumbers => numbers.length > 1;

  DirectoryEntry copyWith({DirectoryPresence? presence}) => DirectoryEntry(
    id: id,
    displayName: displayName,
    numbers: numbers,
    company: company,
    teams: teams,
    telephoneKind: telephoneKind,
    presence: presence ?? this.presence,
    deviceRegistered: deviceRegistered,
  );

  bool get isCompany => telephoneKind == DirectoryTelephoneKind.internal;
  bool get isExternal => telephoneKind == DirectoryTelephoneKind.external;
}

List<String> _stringList(Object? value) {
  final values = value is Iterable && value is! String ? value : [value];
  final seen = <String>{};
  return [
    for (final item in values)
      if ('$item'.trim().isNotEmpty && seen.add('$item'.trim().toLowerCase()))
        '$item'.trim(),
  ];
}

bool? _optionalBool(Object? value) => switch (value) {
  bool flag => flag,
  num number => number != 0,
  String text when text.trim().toLowerCase() == 'true' => true,
  String text when text.trim().toLowerCase() == 'false' => false,
  _ => null,
};

List<String> _numbers(Map<String, dynamic> json) {
  final values = <Object?>[];
  final rawNumbers = json['numbers'] ?? json['telephones'];
  if (rawNumbers is Iterable) {
    values.addAll(rawNumbers);
  }
  final primaryNumber = json['extension'] ?? json['telephone'];
  if (primaryNumber != null) {
    values.add(primaryNumber);
  }

  final seen = <String>{};
  return [
    for (final value in values)
      if ('$value'.trim().isNotEmpty && seen.add('$value'.trim()))
        '$value'.trim(),
  ];
}

DirectoryTelephoneKind _telephoneKind(Object? value) =>
    switch ('$value'.trim().toLowerCase()) {
      'internal' => DirectoryTelephoneKind.internal,
      'external' => DirectoryTelephoneKind.external,
      _ => DirectoryTelephoneKind.unknown,
    };

DirectoryPresence directoryPresenceFromValue(Object? value) =>
    switch ('$value'.trim().toLowerCase()) {
      'available' => DirectoryPresence.available,
      'busy' => DirectoryPresence.busy,
      'ringing' => DirectoryPresence.ringing,
      'unregistered' => DirectoryPresence.unregistered,
      _ => DirectoryPresence.unknown,
    };
