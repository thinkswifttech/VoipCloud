import 'auth_session.dart';

abstract class AuthRepository {
  Future<AuthSession> login({required String email, required String password});

  Future<void> logout();

  Future<AuthSession?> getSession();

  Future<AuthSession> refreshSession(AuthSession session);
}
