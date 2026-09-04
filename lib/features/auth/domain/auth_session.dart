import 'user.dart';

class AuthSession {
  const AuthSession({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
    required this.user,
  });

  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;
  final User user;

  bool get isExpired => DateTime.now().isAfter(expiresAt);

  AuthSession copyWith({
    String? accessToken,
    String? refreshToken,
    DateTime? expiresAt,
    User? user,
  }) {
    return AuthSession(
      accessToken: accessToken ?? this.accessToken,
      refreshToken: refreshToken ?? this.refreshToken,
      expiresAt: expiresAt ?? this.expiresAt,
      user: user ?? this.user,
    );
  }
}
