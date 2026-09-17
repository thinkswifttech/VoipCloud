import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/config_providers.dart';
import '../domain/legal_document.dart';

final legalDocumentRepositoryProvider = Provider<LegalDocumentRepository>((
  ref,
) {
  final config = ref.watch(appConfigProvider);
  return LegalDocumentRepository(uri: config.legalTermsUri);
});

class LegalDocumentRepository {
  LegalDocumentRepository({required Uri? uri, Dio? dio})
    : _uri = uri,
      _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 15),
              headers: const {Headers.acceptHeader: Headers.jsonContentType},
            ),
          );

  static const _maximumBodyBytes = 512 * 1024;
  static final _versionPattern = RegExp(r'^\d{4}-\d{2}-\d{2}$');
  static final _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');

  final Uri? _uri;
  final Dio _dio;

  Future<LegalDocument> getCurrent() async {
    final uri = _uri;
    if (uri == null) {
      throw const FormatException(
        'Legal agreement endpoint is not configured.',
      );
    }

    final response = await _dio.getUri<dynamic>(uri);
    final payload = response.data;
    if (payload is! Map || payload['schema_version'] != 1) {
      throw const FormatException('Unsupported legal agreement response.');
    }

    final documentId = _requiredString(payload, 'document_id');
    final version = _requiredString(payload, 'version');
    final effectiveAt = _requiredString(payload, 'effective_at');
    final title = _requiredString(payload, 'title');
    final expectedHash = _requiredString(payload, 'sha256').toLowerCase();
    final body = _requiredString(payload, 'body');
    final bodyBytes = utf8.encode(body);

    if (!_versionPattern.hasMatch(version) ||
        !_versionPattern.hasMatch(effectiveAt) ||
        !_sha256Pattern.hasMatch(expectedHash) ||
        bodyBytes.length > _maximumBodyBytes) {
      throw const FormatException('Invalid legal agreement metadata.');
    }

    final digest = await Sha256().hash(bodyBytes);
    final actualHash = digest.bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    if (actualHash != expectedHash) {
      throw const FormatException('Legal agreement integrity check failed.');
    }

    return LegalDocument(
      documentId: documentId,
      version: version,
      effectiveAt: effectiveAt,
      title: title,
      sha256: expectedHash,
      body: body,
    );
  }

  static String _requiredString(Map<dynamic, dynamic> payload, String key) {
    final value = payload[key];
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('Legal agreement is missing $key.');
    }
    return value.trim();
  }
}
