class SipRegistrationState {
  const SipRegistrationState({
    required this.status,
    required this.updatedAt,
    this.message,
    this.reconnecting = false,
  });

  factory SipRegistrationState.initial() {
    return SipRegistrationState(
      status: SipRegistrationStatus.uninitialized,
      updatedAt: DateTime.now(),
    );
  }

  final SipRegistrationStatus status;
  final DateTime updatedAt;
  final String? message;

  /// True while registering again after having been connected (a network
  /// change), as opposed to connecting for the first time.
  final bool reconnecting;

  bool get isRegistered => status == SipRegistrationStatus.registered;

  SipRegistrationState copyWith({
    SipRegistrationStatus? status,
    DateTime? updatedAt,
    String? message,
    bool? reconnecting,
  }) {
    return SipRegistrationState(
      status: status ?? this.status,
      updatedAt: updatedAt ?? this.updatedAt,
      message: message ?? this.message,
      reconnecting: reconnecting ?? this.reconnecting,
    );
  }

  @override
  String toString() {
    return 'SipRegistrationState(status: $status, updatedAt: $updatedAt, message: $message)';
  }
}

enum SipRegistrationStatus {
  uninitialized,
  unregistered,
  configuring,
  registering,
  registered,
  failed,
}
