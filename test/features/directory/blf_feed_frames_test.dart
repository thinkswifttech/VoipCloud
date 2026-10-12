import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/features/directory/data/blf_feed_client.dart';
import 'package:phone_app/features/directory/data/blf_feed_frames.dart';
import 'package:phone_app/features/directory/domain/directory_entry.dart';

String frame(Map<String, Object?> json) => jsonEncode(json);

void main() {
  group('frame parsing', () {
    test('hello is parsed and tolerates unknown fields', () {
      final parsed = BlfFeedFrame.parse(
        frame({
          't': 'hello',
          'proto': 1,
          'epoch': 'abcd',
          'seq': 0,
          'serverTime': 1,
          'maxTargets': 100,
          'heartbeatSeconds': 15,
          'future': {'x': 1},
        }),
      );
      expect(parsed, isA<BlfHelloFrame>());
      final hello = parsed as BlfHelloFrame;
      expect(hello.epoch, 'abcd');
      expect(hello.maxTargets, 100);
      expect(hello.heartbeatSeconds, 15);
    });

    test('hello with another protocol version is rejected', () {
      expect(
        () => BlfFeedFrame.parse(
          frame({'t': 'hello', 'proto': 2, 'epoch': 'a', 'seq': 0}),
        ),
        throwsFormatException,
      );
    });

    test('snapshot maps presence, observedAt and freshness', () {
      final parsed =
          BlfFeedFrame.parse(
                frame({
                  't': 'snapshot',
                  'epoch': 'e',
                  'seq': 3,
                  'reqId': 7,
                  'watcher': 'ready',
                  'states': {
                    '103': {'p': 'busy', 'o': 1700000000000, 'f': true},
                    '104': {'p': 'unknown', 'o': null, 'f': false},
                    '105': {'p': 'something-new', 'o': 5, 'f': false},
                  },
                }),
              )
              as BlfStatesFrame;
      expect(parsed.snapshot, isTrue);
      expect(parsed.reqId, 7);
      expect(parsed.states['103']!.presence, DirectoryPresence.busy);
      expect(
        parsed.states['103']!.observedAt,
        DateTime.fromMillisecondsSinceEpoch(1700000000000, isUtc: true),
      );
      expect(parsed.states['103']!.fresh, isTrue);
      expect(parsed.states['104']!.observedAt, isNull);
      expect(parsed.states['105']!.presence, DirectoryPresence.unknown);
    });

    test('delta reads changes and a missing reqId', () {
      final parsed =
          BlfFeedFrame.parse(
                frame({
                  't': 'delta',
                  'epoch': 'e',
                  'seq': 4,
                  'changes': {
                    '103': {'p': 'ringing', 'o': 9, 'f': true},
                  },
                }),
              )
              as BlfStatesFrame;
      expect(parsed.snapshot, isFalse);
      expect(parsed.reqId, isNull);
      expect(parsed.states['103']!.presence, DirectoryPresence.ringing);
    });

    test('unknown frame types and non-frames are ignored', () {
      expect(BlfFeedFrame.parse(frame({'t': 'future', 'seq': 1})), isNull);
      expect(BlfFeedFrame.parse('not json'), isNull);
      expect(BlfFeedFrame.parse('[1,2]'), isNull);
      expect(BlfFeedFrame.parse('{"seq":1}'), isNull);
      expect(BlfFeedFrame.parse('x' * (300 * 1024)), isNull);
    });

    test('invalid payloads of known frames are reported as malformed', () {
      final bad = <Map<String, Object?>>[
        {'t': 'snapshot', 'epoch': 'e', 'seq': 1, 'states': []},
        {'t': 'snapshot', 'epoch': 'e', 'seq': -1, 'states': {}},
        {'t': 'snapshot', 'epoch': '', 'seq': 1, 'states': {}},
        {'t': 'snapshot', 'epoch': 'e', 'seq': '1', 'states': {}},
        {'t': 'snapshot', 'epoch': 'e', 'seq': 1, 'reqId': 'x', 'states': {}},
        {
          't': 'snapshot',
          'epoch': 'e',
          'seq': 1,
          'states': {
            'abc': {'p': 'busy', 'o': 1, 'f': true},
          },
        },
        {
          't': 'snapshot',
          'epoch': 'e',
          'seq': 1,
          'states': {
            '103': {'p': 'busy', 'o': 'x', 'f': true},
          },
        },
        {
          't': 'delta',
          'epoch': 'e',
          'seq': 1,
          'changes': {
            '103': {'p': 'busy', 'o': 1},
          },
        },
        {
          't': 'delta',
          'epoch': 'e',
          'seq': 1,
          'changes': {'103': 'busy'},
        },
        {'t': 'hb', 'epoch': 'e'},
        {'t': 'error', 'fatal': true},
      ];
      for (final json in bad) {
        expect(
          () => BlfFeedFrame.parse(frame(json)),
          throwsFormatException,
          reason: '$json',
        );
      }
    });

    test('capabilities parsing', () {
      final enabled = BlfCapabilities.parse({
        'enabled': true,
        'protocol': 1,
        'wsUrl': 'wss://sip.example.test/blf/v1/ws',
        'maxTargets': 250,
        'heartbeatSeconds': 15,
      });
      expect(enabled.enabled, isTrue);
      expect(enabled.wsUrl!.host, 'sip.example.test');
      expect(BlfCapabilities.parse({'enabled': false}).enabled, isFalse);
      expect(() => BlfCapabilities.parse('x'), throwsFormatException);
      expect(
        () => BlfCapabilities.parse({'enabled': true, 'protocol': 2}),
        throwsFormatException,
      );
    });
  });

  test('backoff follows the schedule with jitter and saturates', () {
    const schedule = [1, 2, 4, 8, 16, 30];
    for (var attempt = 0; attempt < 9; attempt += 1) {
      final base = schedule[attempt.clamp(0, 5)];
      expect(blfFeedBackoffDelay(attempt, 1), Duration(seconds: base));
      expect(
        blfFeedBackoffDelay(attempt, 0),
        Duration(milliseconds: base * 500),
      );
    }
  });
}
