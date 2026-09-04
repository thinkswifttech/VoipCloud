class CurrentUser {
  const CurrentUser({
    required this.id,
    required this.fullName,
    required this.status,
    this.email,
  });

  factory CurrentUser.fromJson(Map<String, dynamic> json) {
    return CurrentUser(
      id: _string(json['id']),
      fullName: _string(json['fullName'], fallback: 'Softphone User'),
      email: _nullableString(json['email']),
      status: UserStatusCodec.parse(_string(json['status'])),
    );
  }

  final String id;
  final String fullName;
  final String? email;
  final UserStatus status;

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'fullName': fullName,
      'email': email,
      'status': status.name.toUpperCase(),
    };
  }
}

enum UserStatus { active, inactive, suspended, unknown }

extension UserStatusCodec on UserStatus {
  static UserStatus parse(String value) {
    return switch (value.trim().toUpperCase()) {
      'ACTIVE' => UserStatus.active,
      'INACTIVE' => UserStatus.inactive,
      'SUSPENDED' => UserStatus.suspended,
      _ => UserStatus.unknown,
    };
  }

  String get label {
    return switch (this) {
      UserStatus.active => 'Active',
      UserStatus.inactive => 'Inactive',
      UserStatus.suspended => 'Suspended',
      UserStatus.unknown => 'Unknown',
    };
  }
}

String _string(Object? value, {String fallback = ''}) {
  if (value == null) {
    return fallback;
  }
  final text = '$value'.trim();
  return text.isEmpty ? fallback : text;
}

String? _nullableString(Object? value) {
  final text = _string(value);
  return text.isEmpty ? null : text;
}
