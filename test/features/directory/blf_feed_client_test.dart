import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:io' show HttpException;

import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/features/directory/data/blf_feed_client.dart';
import 'package:phone_app/features/directory/data/blf_feed_socket.dart';
import 'package:phone_app/features/directory/domain/directory_entry.dart';

class FakeSocket implements BlfFeedSocket {
  final _incoming = StreamController<String>();
  final sent = <Map<String, Object?>>[];
  bool closed = false;
  @override
  int? closeCode;
  @override
  String? closeReason;

  @override
  Stream<String> get messages => _incoming.stream;

  @override
  void add(String message) =>
      sent.add(Map<String, Object?>.from(jsonDecode(message) as Map));

  @override
  Future<void> close() async {
    closed = true;
  }

  void receive(Object frame) =>
      _incoming.add(frame is String ? frame : jsonEncode(frame));

  void serverClose(int? code) {
    closeCode = code;
    unawaited(_incoming.close());
  }

  Iterable<Map<String, Object?>> frames(String type) =>
      sent.where((frame) => frame['t'] == type);
}

class FixedRandom implements Random {
  FixedRandom(this.value);

  final double value;

  @override
  double nextDouble() => value;

  @override
  int nextInt(int max) => 0;

  @override
  bool nextBool() => false;
}

final credentials = BlfFeedCredentials(
  baseUri: Uri.parse('https://sip.example.test/directory'),
  token: 'token-1',
  deviceId: 'device-1',
);

Map<String, Object?> hello({String epoch = 'e1', int seq = 0}) => {
  't': 'hello',
  'proto': 1,
  'epoch': epoch,
  'seq': seq,
  'serverTime': 1,
  'maxTargets': 250,
  'heartbeatSeconds': 15,
};

Map<String, Object?> state(String presence, {int observed = 1000}) => {
  'p': presence,
  'o': observed,
  'f': true,
};

Map<String, Object?> snapshot(
  int seq,
  Map<String, Object?> states, {
  String epoch = 'e1',
  Object? reqId,
}) => {
  't': 'snapshot',
  'epoch': epoch,
  'seq': seq,
  'reqId': reqId,
  'watcher': 'ready',
  'states': states,
};

Map<String, Object?> delta(
  int seq,
  Map<String, Object?> changes, {
  String epoch = 'e1',
}) => {'t': 'delta', 'epoch': epoch, 'seq': seq, 'changes': changes};

class Harness {
  Harness({this.enabled = true, double random = 0, this.capabilitiesError}) {
    client = BlfFeedClient(
      fetchCapabilities: (value) async {
        fetches.add(value);
        final error = capabilitiesError;
        if (error != null) throw error;
        return BlfCapabilities(
          enabled: enabled,
          wsUrl: Uri.parse('wss://sip.example.test/blf/v1/ws'),
        );
      },
      socketFactory: (uri, {required headers, required protocol}) async {
        connections.add((uri: uri, headers: headers, protocol: protocol));
        final rejection = connectError;
        if (rejection != null) throw rejection;
        if (failConnect) throw StateError('connect failed');
        final socket = FakeSocket();
        sockets.add(socket);
        return socket;
      },
      now: () => clock,
      random: FixedRandom(random),
    );
    client.events.listen(events.add);
  }

  late final BlfFeedClient client;
  bool enabled;
  final Object? capabilitiesError;
  bool failConnect = false;
  Object? connectError;
  DateTime clock = DateTime.utc(2026, 10, 8);
  final fetches = <BlfFeedCredentials>[];
  final connections =
      <({Uri uri, Map<String, String> headers, String protocol})>[];
  final sockets = <FakeSocket>[];
  final events = <BlfFeedEvent>[];

  FakeSocket get socket => sockets.last;

  Future<void> connect(WidgetTester tester, {Set<String>? targets}) async {
    client.setTargets(targets ?? {'104', '103'});
    client.setCredentials(credentials);
    await tester.pump();
  }

  /// Connected and authoritative for the current targets.
  Future<void> goLive(WidgetTester tester, {Set<String>? targets}) async {
    await connect(tester, targets: targets);
    socket.receive(hello());
    await tester.pump();
    socket.receive(snapshot(1, {'103': state('busy')}, reqId: 1));
    await tester.pump();
  }
}

Future<void> elapse(WidgetTester tester, Duration duration) async {
  await tester.pump(duration);
  await tester.pump();
}

void main() {
  testWidgets(
    'connects with auth headers and subprotocol, then sends targets',
    (tester) async {
      final h = Harness();
      await h.connect(tester);
      expect(h.fetches.single, credentials);
      expect(
        h.connections.single.uri.toString(),
        'wss://sip.example.test/blf/v1/ws',
      );
      expect(h.connections.single.protocol, 'voipcloud.blf.v1');
      expect(h.connections.single.headers, {
        'Authorization': 'Bearer token-1',
        'X-VoIPCloud-Device-ID': 'device-1',
      });
      expect(h.client.status, BlfFeedStatus.connecting);

      h.socket.receive(hello());
      await tester.pump();
      expect(h.client.status, BlfFeedStatus.connected);
      expect(h.socket.sent.single, {
        't': 'targets',
        'id': 1,
        'set': ['103', '104'],
      });

      h.socket.receive(
        snapshot(1, {
          '103': state('busy'),
          '104': state('available'),
        }, reqId: 1),
      );
      await tester.pump();
      expect(h.client.status, BlfFeedStatus.live);
      final event = h.events.single as BlfFeedSnapshot;
      expect(event.states['103']!.presence, DirectoryPresence.busy);
      expect(event.states['104']!.fresh, isTrue);

      h.socket.receive(delta(2, {'103': state('available', observed: 2000)}));
      await tester.pump();
      final change = h.events.last as BlfFeedDelta;
      expect(change.states['103']!.presence, DirectoryPresence.available);
      await h.client.dispose();
    },
  );

  testWidgets('capabilities are cached for five minutes', (tester) async {
    final h = Harness();
    await h.goLive(tester);
    h.socket.serverClose(4500);
    await tester.pump();
    await elapse(tester, const Duration(seconds: 2));
    expect(h.sockets.length, 2);
    expect(h.fetches.length, 1);

    h.clock = h.clock.add(const Duration(minutes: 5));
    h.socket.serverClose(4500);
    await tester.pump();
    await elapse(tester, const Duration(seconds: 2));
    expect(h.fetches.length, 2);
    await h.client.dispose();
  });

  testWidgets('a disabled Space opens no socket and is re-checked in 5 min', (
    tester,
  ) async {
    final h = Harness(enabled: false);
    await h.connect(tester);
    expect(h.sockets, isEmpty);
    expect(h.client.status, BlfFeedStatus.unavailable);
    expect(
      (h.events.single as BlfFeedLost).reason,
      BlfFeedLossReason.unavailable,
    );

    await elapse(tester, const Duration(minutes: 4, seconds: 59));
    expect(h.fetches.length, 1);
    h.enabled = true;
    await elapse(tester, const Duration(seconds: 2));
    expect(h.fetches.length, 2);
    expect(h.sockets.length, 1);
    await h.client.dispose();
  });

  testWidgets('capabilities auth failure stops until the token changes', (
    tester,
  ) async {
    final h = Harness(capabilitiesError: const BlfFeedAuthException());
    await h.connect(tester);
    expect(h.client.status, BlfFeedStatus.unavailable);
    await elapse(tester, const Duration(minutes: 20));
    expect(h.fetches.length, 1);
    await h.client.dispose();
  });

  group('sequence continuity', () {
    testWidgets('a seq gap requests a resync and drops deltas until snapshot', (
      tester,
    ) async {
      final h = Harness();
      await h.goLive(tester);
      h.events.clear();

      h.socket.receive(delta(3, {'103': state('ringing')}));
      await tester.pump();
      expect(h.socket.frames('resync').length, 1);
      expect(h.events, isEmpty);

      h.socket.receive(delta(4, {'103': state('ringing')}));
      await tester.pump();
      expect(h.socket.frames('resync').length, 1);
      expect(h.events, isEmpty);

      h.socket.receive(snapshot(5, {'103': state('available')}));
      await tester.pump();
      expect((h.events.single as BlfFeedSnapshot).states.length, 1);

      h.socket.receive(delta(6, {'103': state('busy', observed: 3000)}));
      await tester.pump();
      expect(h.events.last, isA<BlfFeedDelta>());
      await h.client.dispose();
    });

    testWidgets('an epoch change resyncs and the new snapshot is adopted', (
      tester,
    ) async {
      final h = Harness();
      await h.goLive(tester);
      h.events.clear();

      h.socket.receive(delta(2, {'103': state('ringing')}, epoch: 'e2'));
      await tester.pump();
      expect(h.socket.frames('resync').length, 1);
      expect(h.events, isEmpty);

      h.socket.receive(snapshot(9, {'103': state('available')}, epoch: 'e2'));
      await tester.pump();
      expect(h.events.single, isA<BlfFeedSnapshot>());
      h.socket.receive(delta(10, {'103': state('busy')}, epoch: 'e2'));
      await tester.pump();
      expect(h.events.last, isA<BlfFeedDelta>());
      await h.client.dispose();
    });

    testWidgets('a heartbeat ahead of the client resyncs, equal does not', (
      tester,
    ) async {
      final h = Harness();
      await h.goLive(tester);
      h.socket.receive({'t': 'hb', 'epoch': 'e1', 'seq': 1});
      await tester.pump();
      expect(h.socket.frames('resync'), isEmpty);
      h.socket.receive({'t': 'hb', 'epoch': 'e1', 'seq': 2});
      await tester.pump();
      expect(h.socket.frames('resync').length, 1);
      await h.client.dispose();
    });

    testWidgets('no snapshot after a resync reconnects after the deadline', (
      tester,
    ) async {
      final h = Harness();
      await h.goLive(tester);
      h.socket.receive(delta(5, {'103': state('ringing')}));
      await tester.pump();
      await elapse(tester, const Duration(seconds: 9));
      expect(h.sockets.first.closed, isTrue);
      expect(h.events.last, isA<BlfFeedLost>());
      await elapse(tester, const Duration(seconds: 2));
      expect(h.sockets.length, 2);
      await h.client.dispose();
    });
  });

  group('close codes', () {
    testWidgets('4401 stops the feed until the token changes', (tester) async {
      final h = Harness();
      await h.goLive(tester);
      h.socket.serverClose(4401);
      await tester.pump();
      expect(h.client.status, BlfFeedStatus.unavailable);
      expect(
        (h.events.last as BlfFeedLost).reason,
        BlfFeedLossReason.unavailable,
      );
      await elapse(tester, const Duration(hours: 1));
      expect(h.sockets.length, 1);

      h.client.setCredentials(
        BlfFeedCredentials(
          baseUri: Uri.parse('https://sip.example.test/directory'),
          token: 'token-2',
          deviceId: 'device-1',
        ),
      );
      await tester.pump();
      expect(h.sockets.length, 2);
      await h.client.dispose();
    });

    testWidgets('4403 re-checks capabilities after five minutes', (
      tester,
    ) async {
      final h = Harness();
      await h.goLive(tester);
      h.socket.serverClose(4403);
      await tester.pump();
      expect(h.client.status, BlfFeedStatus.unavailable);
      await elapse(tester, const Duration(minutes: 4, seconds: 59));
      expect(h.sockets.length, 1);
      await elapse(tester, const Duration(seconds: 2));
      expect(h.fetches.length, 2);
      expect(h.sockets.length, 2);
      await h.client.dispose();
    });

    testWidgets('handshake 401 stops the feed until the token changes', (
      tester,
    ) async {
      final h = Harness()
        ..connectError = const HttpException(
          "was not upgraded to websocket, HTTP status code: 401",
        );
      h.client.setTargets({'103'});
      h.client.setCredentials(credentials);
      await tester.pump();
      await tester.pump();
      expect(h.client.status, BlfFeedStatus.unavailable);
      await elapse(tester, const Duration(hours: 1));
      expect(h.connections.length, 1);
      await h.client.dispose();
    });

    testWidgets('handshake 403 means not enabled and re-checks later', (
      tester,
    ) async {
      final h = Harness()
        ..connectError = const HttpException(
          "was not upgraded to websocket, HTTP status code: 403",
        );
      h.client.setTargets({'103'});
      h.client.setCredentials(credentials);
      await tester.pump();
      await tester.pump();
      expect(h.client.status, BlfFeedStatus.unavailable);
      await elapse(tester, const Duration(minutes: 4, seconds: 59));
      expect(h.connections.length, 1);
      await elapse(tester, const Duration(seconds: 2));
      expect(h.connections.length, 2);
      await h.client.dispose();
    });

    for (final code in [4408, 4429, 4500, 1001, 1006, null]) {
      testWidgets('close $code backs off and reconnects', (tester) async {
        final h = Harness();
        await h.goLive(tester);
        h.socket.serverClose(code);
        await tester.pump();
        expect(h.client.status, BlfFeedStatus.backoff);
        expect(
          (h.events.last as BlfFeedLost).reason,
          BlfFeedLossReason.retrying,
        );
        await elapse(tester, const Duration(seconds: 1));
        expect(h.sockets.length, 2);
        await h.client.dispose();
      });
    }

    testWidgets('repeated failures follow the jittered backoff schedule', (
      tester,
    ) async {
      final h = Harness(random: 1)..failConnect = true;
      await h.connect(tester);
      // random 1.0 => the full steps of 1, 2, 4, 8, 16, 30, 30 seconds.
      var expected = 1;
      for (final step in [1, 2, 4, 8, 16, 30, 30]) {
        expect(h.connections.length, expected);
        await elapse(
          tester,
          Duration(seconds: step) - const Duration(milliseconds: 1),
        );
        expect(h.connections.length, expected);
        await elapse(tester, const Duration(milliseconds: 1));
        expected += 1;
        expect(h.connections.length, expected);
      }
      await h.client.dispose();
    });

    testWidgets('a snapshot resets the backoff', (tester) async {
      final h = Harness(random: 1);
      await h.goLive(tester);
      for (var i = 0; i < 3; i += 1) {
        h.socket.serverClose(4500);
        await tester.pump();
        await elapse(tester, Duration(seconds: 1 << min(i, 5)));
      }
      expect(h.sockets.length, 4);
      h.socket.receive(hello());
      await tester.pump();
      h.socket.receive(snapshot(1, {'103': state('busy')}, reqId: 1));
      await tester.pump();
      h.socket.serverClose(4500);
      await tester.pump();
      await elapse(tester, const Duration(seconds: 1));
      expect(h.sockets.length, 5);
      await h.client.dispose();
    });
  });

  testWidgets('target updates are coalesced to four frames per second', (
    tester,
  ) async {
    final h = Harness();
    await h.goLive(tester);
    await elapse(tester, const Duration(milliseconds: 250));
    expect(h.socket.frames('targets').length, 1);

    h.client.setTargets({'103', '104', '105'});
    h.client.setTargets({'103', '104', '105', '106'});
    h.client.setTargets({'103', '104', '105', '106', '107'});
    await tester.pump();
    expect(h.socket.frames('targets').length, 2);
    expect(h.socket.frames('targets').last['set'], ['103', '104', '105']);

    await elapse(tester, const Duration(milliseconds: 250));
    expect(h.socket.frames('targets').length, 3);
    expect(h.socket.frames('targets').last['id'], 3);
    expect(h.socket.frames('targets').last['set'], [
      '103',
      '104',
      '105',
      '106',
      '107',
    ]);
    await elapse(tester, const Duration(seconds: 1));
    expect(h.socket.frames('targets').length, 3);
    await h.client.dispose();
  });

  testWidgets('a snapshot for an older target request is not authoritative', (
    tester,
  ) async {
    final h = Harness();
    await h.goLive(tester);
    h.events.clear();
    h.client.setTargets({'103', '104', '105'});
    await tester.pump();
    await elapse(tester, const Duration(milliseconds: 250));
    h.socket.receive(snapshot(2, {'103': state('busy')}, reqId: 1));
    await tester.pump();
    expect(h.events, isEmpty);
    h.socket.receive(
      snapshot(3, {'103': state('busy'), '105': state('ringing')}, reqId: 2),
    );
    await tester.pump();
    expect((h.events.single as BlfFeedSnapshot).states.keys, contains('105'));
    await h.client.dispose();
  });

  testWidgets('invalid and non-numeric targets are never sent', (tester) async {
    final h = Harness();
    await h.connect(tester, targets: {'103', 'abc', '1', '123456789', '1 2'});
    h.socket.receive(hello());
    await tester.pump();
    expect(h.socket.frames('targets').single['set'], ['103']);
    await h.client.dispose();
  });

  group('malformed frames', () {
    testWidgets('garbage, unknown types and bad payloads never throw', (
      tester,
    ) async {
      final h = Harness();
      await h.goLive(tester);
      h.events.clear();
      h.socket.receive('not json');
      h.socket.receive('[]');
      h.socket.receive({'t': 'future', 'x': 1});
      h.socket.receive({'t': 'hb', 'epoch': 'e1', 'seq': 1, 'extra': true});
      await tester.pump();
      expect(h.events, isEmpty);
      expect(h.socket.frames('resync'), isEmpty);

      h.socket.receive({'t': 'delta', 'epoch': 'e1', 'seq': 2, 'changes': 5});
      await tester.pump();
      expect(h.events, isEmpty);
      expect(h.socket.frames('resync').length, 1);
      expect(h.client.status, BlfFeedStatus.live);
      await h.client.dispose();
    });

    testWidgets('a stream of malformed frames reconnects', (tester) async {
      final h = Harness();
      await h.goLive(tester);
      for (var i = 0; i < 5; i += 1) {
        h.socket.receive({'t': 'snapshot', 'epoch': 'e1', 'seq': 2});
        await tester.pump();
      }
      expect(h.sockets.first.closed, isTrue);
      expect(h.client.status, BlfFeedStatus.backoff);
      await h.client.dispose();
    });

    testWidgets('frames before hello are ignored; bad hello reconnects', (
      tester,
    ) async {
      final h = Harness();
      await h.connect(tester);
      h.socket.receive(snapshot(1, {'103': state('busy')}, reqId: 1));
      await tester.pump();
      expect(h.events, isEmpty);
      h.socket.receive({'t': 'hello', 'proto': 9, 'epoch': 'e', 'seq': 0});
      await tester.pump();
      expect(h.client.status, BlfFeedStatus.backoff);
      await h.client.dispose();
    });

    testWidgets('a silent connection is dropped by the idle watchdog', (
      tester,
    ) async {
      final h = Harness();
      await h.goLive(tester);
      await elapse(tester, const Duration(seconds: 44));
      expect(h.client.status, BlfFeedStatus.live);
      h.socket.receive({'t': 'hb', 'epoch': 'e1', 'seq': 1});
      await elapse(tester, const Duration(seconds: 44));
      expect(h.client.status, BlfFeedStatus.live);
      await elapse(tester, const Duration(seconds: 2));
      expect(h.sockets.first.closed, isTrue);
      await h.client.dispose();
    });
  });

  group('foreground and release', () {
    testWidgets('background closes the socket; foreground reconnects', (
      tester,
    ) async {
      final h = Harness();
      await h.goLive(tester);
      h.client.setForeground(false);
      await tester.pump();
      expect(h.sockets.first.closed, isTrue);
      expect(h.client.status, BlfFeedStatus.paused);
      expect((h.events.last as BlfFeedLost).reason, BlfFeedLossReason.paused);
      await elapse(tester, const Duration(minutes: 10));
      expect(h.sockets.length, 1);

      h.client.setForeground(true);
      await tester.pump();
      expect(h.sockets.length, 2);
      h.socket.receive(hello(epoch: 'e9'));
      await tester.pump();
      expect(h.socket.frames('targets').length, 1);
      h.socket.receive(
        snapshot(1, {'103': state('busy')}, epoch: 'e9', reqId: 1),
      );
      await tester.pump();
      expect(h.events.last, isA<BlfFeedSnapshot>());
      await h.client.dispose();
    });

    testWidgets('release closes the socket and ignores stale credentials', (
      tester,
    ) async {
      final h = Harness();
      await h.goLive(tester);
      await h.client.release();
      expect(h.sockets.first.closed, isTrue);
      expect(h.client.status, BlfFeedStatus.stopped);

      h.client.setCredentials(credentials);
      await tester.pump();
      expect(h.sockets.length, 1);

      h.client.setCredentials(null);
      h.client.setCredentials(credentials);
      await tester.pump();
      expect(h.sockets.length, 2);
      await h.client.dispose();
    });

    testWidgets('no connection without credentials or targets', (tester) async {
      final h = Harness();
      h.client.setTargets({'103'});
      await tester.pump();
      h.client.setCredentials(credentials);
      h.client.setTargets({});
      await tester.pump();
      expect(h.sockets, isEmpty);
      expect(h.client.status, BlfFeedStatus.stopped);
      await h.client.dispose();
    });
  });

  group('degraded server watcher', () {
    Map<String, Object?> withWatcher(Map<String, Object?> frame, String w) => {
      ...frame,
      'watcher': w,
    };

    testWidgets('degraded reports one loss and keeps the socket open', (
      tester,
    ) async {
      final h = Harness();
      await h.goLive(tester);
      h.events.clear();

      h.socket.receive(
        withWatcher(
          delta(2, {
            '103': {'p': 'busy', 'o': 1000, 'f': false},
          }),
          'degraded',
        ),
      );
      await tester.pump();
      expect(h.events.whereType<BlfFeedLost>().length, 1);
      expect(
        h.events.whereType<BlfFeedLost>().single.reason,
        BlfFeedLossReason.retrying,
      );
      h.socket.receive(
        withWatcher({'t': 'hb', 'epoch': 'e1', 'seq': 2}, 'degraded'),
      );
      h.socket.receive(
        withWatcher(
          delta(3, {
            '103': {'p': 'busy', 'o': 1100, 'f': false},
          }),
          'degraded',
        ),
      );
      await tester.pump();
      expect(h.events.whereType<BlfFeedLost>().length, 1);
      expect(h.sockets.first.closed, isFalse);
      expect(h.sockets.length, 1);
      await h.client.dispose();
    });

    testWidgets('recovery sends a resync and the snapshot ends the episode', (
      tester,
    ) async {
      final h = Harness();
      await h.goLive(tester);
      h.socket.receive(
        withWatcher({'t': 'hb', 'epoch': 'e1', 'seq': 1}, 'degraded'),
      );
      await tester.pump();
      expect(h.socket.frames('resync'), isEmpty);

      h.socket.receive(
        withWatcher({'t': 'hb', 'epoch': 'e1', 'seq': 1}, 'starting'),
      );
      await tester.pump();
      expect(h.socket.frames('resync').length, 1);
      h.events.clear();

      h.socket.receive(
        withWatcher(snapshot(2, {'103': state('busy')}), 'ready'),
      );
      await tester.pump();
      expect(h.events.single, isA<BlfFeedSnapshot>());
      expect(h.socket.frames('resync').length, 1);

      // A later episode is reported again.
      h.socket.receive(
        withWatcher({'t': 'hb', 'epoch': 'e1', 'seq': 2}, 'degraded'),
      );
      await tester.pump();
      expect(h.events.last, isA<BlfFeedLost>());
      await h.client.dispose();
    });

    testWidgets('a recovering snapshot needs no extra resync', (tester) async {
      final h = Harness();
      await h.goLive(tester);
      h.socket.receive(
        withWatcher({'t': 'hb', 'epoch': 'e1', 'seq': 1}, 'degraded'),
      );
      await tester.pump();
      h.socket.receive(
        withWatcher(snapshot(2, {'103': state('busy')}), 'ready'),
      );
      await tester.pump();
      expect(h.events.last, isA<BlfFeedSnapshot>());
      expect(h.socket.frames('resync'), isEmpty);
      await h.client.dispose();
    });

    testWidgets('a socket drop while degraded follows the normal backoff', (
      tester,
    ) async {
      final h = Harness();
      await h.goLive(tester);
      h.socket.receive(
        withWatcher({'t': 'hb', 'epoch': 'e1', 'seq': 1}, 'degraded'),
      );
      await tester.pump();
      h.socket.serverClose(4500);
      await tester.pump();
      expect(h.client.status, BlfFeedStatus.backoff);
      await elapse(tester, const Duration(seconds: 1));
      expect(h.sockets.length, 2);
      h.socket.receive(hello(epoch: 'e2'));
      await tester.pump();
      h.socket.receive(
        snapshot(1, {'103': state('busy')}, epoch: 'e2', reqId: 1),
      );
      await tester.pump();
      expect(h.events.last, isA<BlfFeedSnapshot>());
      await h.client.dispose();
    });

    testWidgets('a missing or unknown watcher behaves as healthy', (
      tester,
    ) async {
      final h = Harness();
      await h.goLive(tester);
      h.events.clear();
      h.socket.receive(withWatcher({'t': 'hb', 'epoch': 'e1', 'seq': 1}, 'x'));
      h.socket.receive({'t': 'hb', 'epoch': 'e1', 'seq': 1, 'watcher': 5});
      h.socket.receive(delta(2, {'103': state('ringing')}));
      await tester.pump();
      expect(h.events.single, isA<BlfFeedDelta>());
      expect(h.socket.frames('resync'), isEmpty);
      await h.client.dispose();
    });
  });
}
