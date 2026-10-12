import 'package:dio/dio.dart';

import '../../../core/logging/app_logger.dart';
import '../domain/link_shortening.dart';

/// Turns long links in an outgoing text into short ones. Never throws:
/// when a link cannot be shortened the original text is sent unchanged.
abstract class LinkShortener {
  Future<String> shorten(String text);
}

class NoopLinkShortener implements LinkShortener {
  const NoopLinkShortener();

  @override
  Future<String> shorten(String text) async => text;
}

typedef MessagingAccessToken = Future<String> Function({bool forceRefresh});

/// Calls `POST /api/v1/links` on the link service with the messaging token.
class ApiLinkShortener implements LinkShortener {
  ApiLinkShortener({
    required this.baseUrl,
    required MessagingAccessToken accessToken,
    required Dio dio,
    this.minLength = 50,
    this.maxLinks = 5,
  }) : _accessToken = accessToken,
       _dio = dio;

  final String baseUrl;
  final int minLength;
  final int maxLinks;
  final MessagingAccessToken _accessToken;
  final Dio _dio;

  @override
  Future<String> shorten(String text) async {
    final links = linksToShorten(
      text,
      minLength: minLength,
      skipOrigin: baseUrl,
      maxLinks: maxLinks,
    );
    if (links.isEmpty) return text;
    final replacements = <String, String>{};
    for (final link in links) {
      final short = await _create(link);
      // One failure (service down, rate limited) is not retried per link:
      // the rest are left as typed so sending is never held up.
      if (short == null) break;
      if (short.length < link.length) replacements[link] = short;
    }
    return replacements.isEmpty ? text : replaceLinks(text, replacements);
  }

  Future<String?> _create(String url) async {
    try {
      return await _post(url, forceRefresh: false);
    } on _Unauthorized {
      try {
        return await _post(url, forceRefresh: true);
      } catch (error) {
        _logFailure(error);
        return null;
      }
    } catch (error) {
      _logFailure(error);
      return null;
    }
  }

  Future<String?> _post(String url, {required bool forceRefresh}) async {
    final token = await _accessToken(forceRefresh: forceRefresh);
    try {
      final response = await _dio.post<Object?>(
        '${baseUrl.replaceAll(RegExp(r'/+$'), '')}/api/v1/links',
        data: {'url': url},
        options: Options(
          headers: {'Authorization': 'Bearer $token'},
          contentType: Headers.jsonContentType,
          responseType: ResponseType.json,
          sendTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 10),
        ),
      );
      final data = response.data;
      final short = data is Map ? data['shortUrl'] : null;
      if (short is! String || !_isSafeShortUrl(short)) return null;
      return short;
    } on DioException catch (error) {
      if (error.response?.statusCode == 401) throw const _Unauthorized();
      rethrow;
    }
  }

  /// The service decides the short URL, but the app only accepts one on the
  /// host it was configured with, so a bad response cannot redirect people
  /// somewhere else.
  bool _isSafeShortUrl(String short) {
    final uri = Uri.tryParse(short);
    final base = Uri.tryParse(baseUrl);
    return uri != null &&
        base != null &&
        uri.scheme == 'https' &&
        uri.host.isNotEmpty &&
        uri.host.toLowerCase() == base.host.toLowerCase() &&
        uri.userInfo.isEmpty;
  }

  void _logFailure(Object error) {
    // Status and reason only: never the link, token or response body.
    if (error is DioException) {
      final data = error.response?.data;
      final reason = data is Map ? data['reason'] ?? data['code'] : null;
      AppLogger.info(
        'Link shortening skipped status=${error.response?.statusCode ?? error.type.name} reason=${reason ?? "none"}',
      );
      return;
    }
    AppLogger.info('Link shortening skipped (${error.runtimeType})');
  }
}

class _Unauthorized implements Exception {
  const _Unauthorized();
}
