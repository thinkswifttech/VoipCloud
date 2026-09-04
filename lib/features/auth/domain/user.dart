class User {
  const User({
    required this.id,
    required this.email,
    required this.displayName,
    this.organizationId,
    this.phoneNumber,
    this.role,
    this.status,
    this.extension,
  });

  final String id;
  final String? organizationId;
  final String email;
  final String? phoneNumber;
  final String displayName;
  final String? role;
  final String? status;
  final String? extension;

  User copyWith({
    String? id,
    String? organizationId,
    String? email,
    String? phoneNumber,
    String? displayName,
    String? role,
    String? status,
    String? extension,
  }) {
    return User(
      id: id ?? this.id,
      organizationId: organizationId ?? this.organizationId,
      email: email ?? this.email,
      phoneNumber: phoneNumber ?? this.phoneNumber,
      displayName: displayName ?? this.displayName,
      role: role ?? this.role,
      status: status ?? this.status,
      extension: extension ?? this.extension,
    );
  }
}
