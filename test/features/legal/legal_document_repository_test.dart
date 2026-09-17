import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/features/legal/data/legal_document_repository.dart';

void main() {
  test('loads a valid checksummed legal document', () async {
    const body = 'ThinkSwift Master Services Agreement\nApproved terms';
    final repository = LegalDocumentRepository(
      uri: Uri.parse('https://updates.example.test/legal/terms/current.json'),
      dio: _responseDio(await _payload(body)),
    );

    final document = await repository.getCurrent();

    expect(document.documentId, 'thinkswift-msa');
    expect(document.version, '2026-08-11');
    expect(document.body, body);
  });

  test('rejects a document whose body does not match its checksum', () async {
    final payload = await _payload('Approved terms');
    payload['body'] = 'Tampered terms';
    final repository = LegalDocumentRepository(
      uri: Uri.parse('https://updates.example.test/legal/terms/current.json'),
      dio: _responseDio(payload),
    );

    await expectLater(repository.getCurrent(), throwsA(isA<FormatException>()));
  });

  test('fails closed when the endpoint is not configured', () async {
    final repository = LegalDocumentRepository(uri: null);

    await expectLater(repository.getCurrent(), throwsA(isA<FormatException>()));
  });
}

Future<Map<String, dynamic>> _payload(String body) async {
  final digest = await Sha256().hash(utf8.encode(body));
  final sha256 = digest.bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return {
    'schema_version': 1,
    'document_id': 'thinkswift-msa',
    'version': '2026-08-11',
    'effective_at': '2026-08-11',
    'title': 'ThinkSwift Master Services Agreement',
    'sha256': sha256,
    'body': body,
  };
}

Dio _responseDio(Map<String, dynamic> payload) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
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
