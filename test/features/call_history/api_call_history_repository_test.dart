import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/core/constants/storage_keys.dart';
import 'package:phone_app/core/storage/secure_storage_service.dart';
import 'package:phone_app/features/call_history/data/api_call_history_repository.dart';
import 'package:phone_app/features/call_history/domain/call_history_item.dart';
import 'package:phone_app/voip/platform/voip_platform_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('ignores provisional and unknown server call states', () async {
    final storage = InMemorySecureStorageService();
    await storage.write(
      StorageKeys.appDirectoryAccess,
      jsonEncode({
        'endpoint': 'https://sip.example.test/',
        'token': 'directory-token',
      }),
    );
    final repository = ApiCallHistoryRepository(
      storage: storage,
      endpointPath: Uri.parse('/api/voipcloud/calls/history'),
      dio: _responseDio({
        'content': [
          _call(id: 'provisional', status: 'IN_PROGRESS'),
          _call(id: 'future-status', status: 'SOMETHING_NEW'),
          _call(id: 'completed', status: 'MISSED'),
        ],
        'lastPage': 1,
      }),
    );

    final history = await repository.getCallHistory();

    expect(history, hasLength(1));
    expect(history.single.id, 'completed');
    expect(history.single.effectiveDisposition, CallHistoryDisposition.missed);
  });

  test('sends authenticated app and SIP device identities', () async {
    final storage = InMemorySecureStorageService();
    await storage.write(
      StorageKeys.appDirectoryAccess,
      jsonEncode({
        'endpoint': 'https://sip.example.test/',
        'token': 'directory-token',
      }),
    );
    await storage.write(StorageKeys.appDeviceId, 'device-123');
    Map<String, dynamic>? requestHeaders;
    final repository = ApiCallHistoryRepository(
      storage: storage,
      endpointPath: Uri.parse('/api/voipcloud/calls/history'),
      platformChannel: const _FakeVoipPlatformChannel(
        'bc5e57e7-448b-4587-8ce9-af1d11090c91',
      ),
      dio: _responseDio({
        'content': const [],
        'lastPage': 1,
      }, onRequest: (options) => requestHeaders = options.headers),
    );

    await repository.getCallHistory();

    expect(requestHeaders?['X-VoIPCloud-Device-ID'], 'device-123');
    expect(
      requestHeaders?['X-VoIPCloud-SIP-Device-ID'],
      'bc5e57e7-448b-4587-8ce9-af1d11090c91',
    );
  });
}

class _FakeVoipPlatformChannel extends VoipPlatformChannel {
  const _FakeVoipPlatformChannel(this.deviceId);

  final String deviceId;

  @override
  Future<String?> getSipInstanceId() async => deviceId;
}

Map<String, Object?> _call({required String id, required String status}) => {
  'id': id,
  'remoteParty': '211',
  'remoteDisplayName': 'TEST: Abdul Test User',
  'direction': 'INBOUND',
  'status': status,
  'startedAt': '2026-09-29T19:50:00Z',
  'endedAt': status == 'IN_PROGRESS' ? null : '2026-09-29T19:50:08Z',
};

Dio _responseDio(
  Map<String, dynamic> payload, {
  void Function(RequestOptions options)? onRequest,
}) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        onRequest?.call(options);
        handler.resolve(
          Response<dynamic>(
            requestOptions: options,
            statusCode: 200,
            data: payload,
          ),
        );
      },
    ),
  );
  return dio;
}
