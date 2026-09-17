import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/core/constants/storage_keys.dart';
import 'package:phone_app/core/network/dio_provider.dart';
import 'package:phone_app/core/storage/secure_storage_service.dart';
import 'package:phone_app/core/storage/storage_providers.dart';

void main() {
  test(
    'an HTTP 401 never deletes locally provisioned SIP credentials',
    () async {
      final storage = InMemorySecureStorageService();
      await storage.write(StorageKeys.appAccessToken, 'expired-control-token');
      await storage.write(StorageKeys.appSipConfig, '{"sip":"still-valid"}');
      final container = ProviderContainer(
        overrides: [secureStorageProvider.overrideWithValue(storage)],
      );
      addTearDown(container.dispose);
      final dio = container.read(dioProvider)
        ..httpClientAdapter = const _UnauthorizedAdapter();

      await expectLater(
        dio.get<void>('/api/app/config'),
        throwsA(isA<DioException>()),
      );

      expect(await storage.read(StorageKeys.appAccessToken), isNotNull);
      expect(await storage.read(StorageKeys.appSipConfig), isNotNull);
    },
  );
}

class _UnauthorizedAdapter implements HttpClientAdapter {
  const _UnauthorizedAdapter();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      '{"message":"Unauthorized"}',
      401,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
