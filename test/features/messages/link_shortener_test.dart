import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/features/messages/data/link_shortener.dart';
import 'package:phone_app/features/messages/domain/link_shortening.dart';

const _long =
    'https://docs.example.test/a/very/long/path/to/a/shared/document?token=abcdefghijklmnopqrstuvwxyz';

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);

  final ResponseBody Function(RequestOptions options) handler;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(int status, Map<String, Object?> body) =>
    ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

ApiLinkShortener _shortener(
  _FakeAdapter adapter, {
  List<bool>? refreshes,
  String token = 'tok',
}) {
  final dio = Dio()..httpClientAdapter = adapter;
  return ApiLinkShortener(
    baseUrl: 'https://go.example.test',
    dio: dio,
    accessToken: ({bool forceRefresh = false}) async {
      refreshes?.add(forceRefresh);
      return forceRefresh ? 'fresh' : token;
    },
  );
}

void main() {
  group('linksToShorten', () {
    test('ignores short links and plain text', () {
      expect(
        linksToShorten('hi https://a.example/x ok', minLength: 50),
        isEmpty,
      );
      expect(linksToShorten('no links here', minLength: 50), isEmpty);
    });

    test('finds long links and drops trailing punctuation', () {
      expect(linksToShorten('See $_long.', minLength: 50), [_long]);
      expect(linksToShorten('($_long)', minLength: 50), [_long]);
      expect(linksToShorten('"$_long", thanks', minLength: 50), [_long]);
    });

    test('keeps a closing bracket that belongs to the link', () {
      const link =
          'https://en.example.test/wiki/Some_long_article_name_(disambiguation_page_here)';
      expect(linksToShorten('x $link y', minLength: 50), [link]);
    });

    test('de-duplicates, caps the count and skips the shortener itself', () {
      final many = [for (var i = 0; i < 8; i++) '$_long&n=$i'].join(' ');
      expect(linksToShorten(many, minLength: 50, maxLinks: 3), hasLength(3));
      expect(linksToShorten('$_long $_long', minLength: 50), [_long]);
      expect(
        linksToShorten(
          'https://go.example.test/abcdefghijkl/mnopqrstuvwxyz0123456789abcdefghijklmnop',
          minLength: 50,
          skipOrigin: 'https://go.example.test',
        ),
        isEmpty,
      );
    });
  });

  test('replaceLinks rewrites the longest link first', () {
    const shorter = 'https://a.example.test/one/two/three';
    const longer = 'https://a.example.test/one/two/three/four';
    final text = '$shorter and $longer';
    expect(replaceLinks(text, {shorter: 'S', longer: 'L'}), 'S and L');
  });

  group('ApiLinkShortener', () {
    test('replaces a long link with the returned short link', () async {
      final adapter = _FakeAdapter(
        (_) => _json(201, {
          'shortUrl': 'https://go.example.test/k7mq2x9ta',
          'code': 'k7mq2x9ta',
        }),
      );
      final result = await _shortener(adapter).shorten('Open $_long please');

      expect(result, 'Open https://go.example.test/k7mq2x9ta please');
      expect(adapter.requests.single.headers['Authorization'], 'Bearer tok');
      expect(
        adapter.requests.single.path,
        'https://go.example.test/api/v1/links',
      );
      expect(
        jsonDecode(
          adapter.requests.single.data is String
              ? adapter.requests.single.data as String
              : jsonEncode(adapter.requests.single.data),
        ),
        {'url': _long},
      );
    });

    test('does nothing when there is no long link', () async {
      final adapter = _FakeAdapter((_) => _json(500, {}));
      expect(await _shortener(adapter).shorten('hello'), 'hello');
      expect(adapter.requests, isEmpty);
    });

    test(
      'keeps the original link when the service fails and stops trying',
      () async {
        final adapter = _FakeAdapter(
          (_) => _json(503, {'code': 'service_unavailable'}),
        );
        final text = '$_long and $_long&other=1';
        expect(await _shortener(adapter).shorten(text), text);
        expect(adapter.requests, hasLength(1));
      },
    );

    test('keeps the original link when rate limited or rejected', () async {
      for (final status in [422, 429]) {
        final adapter = _FakeAdapter((_) => _json(status, {'code': 'x'}));
        expect(await _shortener(adapter).shorten(_long), _long);
      }
    });

    test('refreshes the session once after a 401 and retries', () async {
      var calls = 0;
      final adapter = _FakeAdapter((options) {
        calls++;
        if (calls == 1) return _json(401, {'code': 'unauthorized'});
        return _json(200, {'shortUrl': 'https://go.example.test/abc23456'});
      });
      final refreshes = <bool>[];
      final result = await _shortener(
        adapter,
        refreshes: refreshes,
      ).shorten(_long);

      expect(result, 'https://go.example.test/abc23456');
      expect(refreshes, [false, true]);
      expect(adapter.requests.last.headers['Authorization'], 'Bearer fresh');
    });

    test('gives up quietly when 401 persists', () async {
      final adapter = _FakeAdapter((_) => _json(401, {'code': 'unauthorized'}));
      expect(await _shortener(adapter).shorten(_long), _long);
      expect(adapter.requests, hasLength(2));
    });

    test('ignores a short URL on another host or without https', () async {
      for (final bad in [
        'https://evil.example.test/abc',
        'http://go.example.test/abc',
        'https://user@go.example.test/abc',
        'not a url',
      ]) {
        final adapter = _FakeAdapter((_) => _json(201, {'shortUrl': bad}));
        expect(await _shortener(adapter).shorten(_long), _long, reason: bad);
      }
    });

    test('never makes the message longer', () async {
      final adapter = _FakeAdapter(
        (_) => _json(201, {'shortUrl': 'https://go.example.test/${'a' * 200}'}),
      );
      expect(await _shortener(adapter).shorten(_long), _long);
    });

    test('does not shorten links that already point at the service', () async {
      final adapter = _FakeAdapter((_) => _json(500, {}));
      const own =
          'https://go.example.test/k7mq2x9tak7mq2x9tak7mq2x9tak7mq2x9tak7mq2x9tak7mq2x9ta';
      expect(await _shortener(adapter).shorten(own), own);
      expect(adapter.requests, isEmpty);
    });
  });
}
