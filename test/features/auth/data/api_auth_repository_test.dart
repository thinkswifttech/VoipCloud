import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/core/constants/storage_keys.dart';
import 'package:phone_app/core/network/app_client.dart';
import 'package:phone_app/core/storage/secure_storage_service.dart';
import 'package:phone_app/features/auth/data/api_auth_repository.dart';

void main() {
  test('login persists and logout clears session tokens', () async {
    final storage = InMemorySecureStorageService();
    final adapter = _FakeHttpClientAdapter({
      'POST /api/v1/auth/login': _jsonResponse({
        'accessToken': 'access-token',
        'refreshToken': 'refresh-token',
        'expiresIn': 900,
        'user': {
          'id': 'user-id',
          'organizationId': 'org-id',
          'email': 'agent@voipcloud.local',
          'phoneNumber': '+15551234567',
          'displayName': 'Agent',
          'status': 'ACTIVE',
          'role': 'USER',
        },
      }),
      'POST /api/v1/auth/logout': ResponseBody.fromString('', 204),
    });
    final dio = Dio(BaseOptions(baseUrl: 'https://api.example.test'))
      ..httpClientAdapter = adapter;
    final repository = ApiAuthRepository(
      client: AppClient(dio),
      storage: storage,
    );

    final session = await repository.login(
      email: 'Agent@VoipCloud.Local',
      password: 'password123',
    );

    expect(session.user.email, 'agent@voipcloud.local');
    expect(session.user.role, 'USER');
    expect(await storage.read(StorageKeys.authAccessToken), 'access-token');

    await repository.logout();

    expect(await repository.getSession(), isNull);
    expect(await storage.read(StorageKeys.authAccessToken), isNull);
  });
}

ResponseBody _jsonResponse(Map<String, Object?> body) {
  return ResponseBody.fromString(
    jsonEncode(body),
    200,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );
}

class _FakeHttpClientAdapter implements HttpClientAdapter {
  const _FakeHttpClientAdapter(this._responses);

  final Map<String, ResponseBody> _responses;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final response = _responses['${options.method} ${options.path}'];
    if (response == null) {
      return ResponseBody.fromString('Not found', 404);
    }
    return response;
  }

  @override
  void close({bool force = false}) {}
}
