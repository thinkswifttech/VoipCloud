import '../../../core/constants/storage_keys.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/network/app_client.dart';
import '../../../core/storage/secure_storage_service.dart';
import '../domain/auth_repository.dart';
import '../domain/auth_session.dart';
import '../domain/user.dart';

class ApiAuthRepository implements AuthRepository {
  ApiAuthRepository({
    required AppClient client,
    required SecureStorageService storage,
  }) : _client = client,
       _storage = storage;

  final AppClient _client;
  final SecureStorageService _storage;

  @override
  Future<AuthSession> login({
    required String email,
    required String password,
  }) async {
    if (email.trim().isEmpty || password.isEmpty) {
      throw const AuthException(
        message: 'Missing email or password',
        userMessage: 'Enter your email and password.',
      );
    }

    final response = await _client.post<Map<String, dynamic>>(
      '/api/v1/auth/login',
      data: {'email': email.trim(), 'password': password},
    );
    final session = _sessionFromJson(response.data);
    await _persist(session);
    return session;
  }

  @override
  Future<void> logout() async {
    final refreshToken = await _storage.read(StorageKeys.authRefreshToken);
    try {
      if (refreshToken != null && refreshToken.isNotEmpty) {
        await _client.post<void>(
          '/api/v1/auth/logout',
          data: {'refreshToken': refreshToken},
        );
      }
    } finally {
      await _clearSession();
    }
  }

  @override
  Future<AuthSession?> getSession() async {
    final accessToken = await _storage.read(StorageKeys.authAccessToken);
    final refreshToken = await _storage.read(StorageKeys.authRefreshToken);
    final expiresAtRaw = await _storage.read(StorageKeys.authExpiresAt);
    final userId = await _storage.read(StorageKeys.authUserId);
    final email = await _storage.read(StorageKeys.authUserEmail);
    final displayName = await _storage.read(StorageKeys.authUserDisplayName);

    if (accessToken == null ||
        refreshToken == null ||
        expiresAtRaw == null ||
        userId == null ||
        email == null ||
        displayName == null) {
      return null;
    }

    final expiresAt = DateTime.tryParse(expiresAtRaw);
    if (expiresAt == null) {
      await _clearSession();
      return null;
    }

    return AuthSession(
      accessToken: accessToken,
      refreshToken: refreshToken,
      expiresAt: expiresAt,
      user: User(
        id: userId,
        email: email,
        displayName: displayName,
        organizationId: await _storage.read(StorageKeys.authOrganizationId),
        phoneNumber: await _storage.read(StorageKeys.authUserPhoneNumber),
        role: await _storage.read(StorageKeys.authUserRole),
        status: await _storage.read(StorageKeys.authUserStatus),
        extension: await _storage.read(StorageKeys.authUserExtension),
      ),
    );
  }

  @override
  Future<AuthSession> refreshSession(AuthSession session) async {
    final response = await _client.post<Map<String, dynamic>>(
      '/api/v1/auth/refresh',
      data: {'refreshToken': session.refreshToken},
    );
    final refreshed = _sessionFromJson(response.data);
    await _persist(refreshed);
    return refreshed;
  }

  AuthSession _sessionFromJson(Map<String, dynamic>? json) {
    if (json == null) {
      throw const AuthException(message: 'Missing authentication response');
    }

    final accessToken = _requiredString(json, 'accessToken');
    final refreshToken = _requiredString(json, 'refreshToken');
    final expiresIn = json['expiresIn'];
    final userJson = json['user'];
    if (userJson is! Map) {
      throw const AuthException(message: 'Missing authenticated user');
    }

    return AuthSession(
      accessToken: accessToken,
      refreshToken: refreshToken,
      expiresAt: DateTime.now().add(
        Duration(seconds: expiresIn is num ? expiresIn.toInt() : 0),
      ),
      user: _userFromJson(Map<String, dynamic>.from(userJson)),
    );
  }

  User _userFromJson(Map<String, dynamic> json) {
    return User(
      id: _requiredString(json, 'id'),
      organizationId: _stringOrNull(json['organizationId']),
      email: _requiredString(json, 'email'),
      phoneNumber: _stringOrNull(json['phoneNumber']),
      displayName: _requiredString(json, 'displayName'),
      role: _stringOrNull(json['role']),
      status: _stringOrNull(json['status']),
    );
  }

  Future<void> _persist(AuthSession session) async {
    await _storage.write(StorageKeys.authAccessToken, session.accessToken);
    await _storage.write(StorageKeys.authRefreshToken, session.refreshToken);
    await _storage.write(
      StorageKeys.authExpiresAt,
      session.expiresAt.toIso8601String(),
    );
    await _storage.write(StorageKeys.authUserId, session.user.id);
    await _storage.write(StorageKeys.authUserEmail, session.user.email);
    await _storage.write(
      StorageKeys.authUserDisplayName,
      session.user.displayName,
    );
    await _writeOptional(
      StorageKeys.authOrganizationId,
      session.user.organizationId,
    );
    await _writeOptional(
      StorageKeys.authUserPhoneNumber,
      session.user.phoneNumber,
    );
    await _writeOptional(StorageKeys.authUserRole, session.user.role);
    await _writeOptional(StorageKeys.authUserStatus, session.user.status);
    await _writeOptional(StorageKeys.authUserExtension, session.user.extension);
  }

  Future<void> _writeOptional(String key, String? value) {
    if (value == null || value.isEmpty) {
      return _storage.delete(key);
    }
    return _storage.write(key, value);
  }

  Future<void> _clearSession() async {
    await _storage.delete(StorageKeys.authAccessToken);
    await _storage.delete(StorageKeys.authRefreshToken);
    await _storage.delete(StorageKeys.authExpiresAt);
    await _storage.delete(StorageKeys.authUserId);
    await _storage.delete(StorageKeys.authOrganizationId);
    await _storage.delete(StorageKeys.authUserEmail);
    await _storage.delete(StorageKeys.authUserPhoneNumber);
    await _storage.delete(StorageKeys.authUserDisplayName);
    await _storage.delete(StorageKeys.authUserRole);
    await _storage.delete(StorageKeys.authUserStatus);
    await _storage.delete(StorageKeys.authUserExtension);
  }

  String _requiredString(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is String && value.isNotEmpty) {
      return value;
    }
    throw AuthException(message: 'Missing "$key" in authentication response');
  }

  String? _stringOrNull(Object? value) => value == null ? null : '$value';
}
