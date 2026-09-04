enum SipRegistrationStatus {
  uninitialized,
  unregistered,
  configuring,
  registering,
  registered,
  failed,
}

class SipRegistrationState {
  const SipRegistrationState({
    required this.status,
    required this.updatedAt,
    this.message,
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

  bool get isRegistered => status == SipRegistrationStatus.registered;

  SipRegistrationState copyWith({
    SipRegistrationStatus? status,
    DateTime? updatedAt,
    String? message,
  }) {
    return SipRegistrationState(
      status: status ?? this.status,
      updatedAt: updatedAt ?? this.updatedAt,
      message: message ?? this.message,
    );
  }
}
