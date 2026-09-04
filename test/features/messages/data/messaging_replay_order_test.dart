import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/features/messages/data/messaging_replay_order.dart';

void main() {
  test('orders replay events and ignores stale or malformed sequences', () {
    final events = orderedMessagingEventsAfter([
      {'sequence': 8, 'event_type': 'message.delivered'},
      {'sequence': 6, 'event_type': 'message.submitted'},
      {'sequence': 7, 'event_type': 'message.sent'},
      {'sequence': 5, 'event_type': 'message.queued'},
      {'sequence': 'invalid', 'event_type': 'message.failed'},
    ], after: 5);

    expect(events.map((event) => event['sequence']), [6, 7, 8]);
  });

  test('accepts numeric string sequences without moving the cursor back', () {
    final events = orderedMessagingEventsAfter([
      {'sequence': '12'},
      {'sequence': '10'},
      {'sequence': '11'},
    ], after: 10);

    expect(events.map((event) => event['sequence']), ['11', '12']);
  });
}
