import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/features/messages/domain/carrier_message.dart';
import 'package:phone_app/features/messages/domain/message_delivery_status.dart';

CarrierMessage _message(
  MessageStatus status, {
  String id = 'server-id',
  String clientId = 'client-id',
  String? errorCode,
  int segmentCount = 1,
  int segmentsSubmitted = 0,
  MessageDirection direction = MessageDirection.outgoing,
}) {
  return CarrierMessage(
    id: id,
    clientId: clientId,
    remoteNumber: '+14165550123',
    direction: direction,
    text: 'hi',
    status: status,
    createdAt: DateTime(2026, 10, 14, 11, 25),
    errorCode: errorCode,
    segmentCount: segmentCount,
    segmentsSubmitted: segmentsSubmitted,
  );
}

void main() {
  test('a message only on this phone shows a clock', () {
    final info = describeMessageDelivery(
      _message(MessageStatus.sending, id: 'client-id'),
    )!;
    expect(info.stage, MessageDeliveryStage.sending);
    expect(info.ticks, 0);
  });

  test('single tick once VoipCloud has the message', () {
    for (final status in [MessageStatus.queued, MessageStatus.sending]) {
      final info = describeMessageDelivery(_message(status))!;
      expect(info.stage, MessageDeliveryStage.withVoipCloud);
      expect(info.ticks, 1);
    }
  });

  test('double tick once the carrier accepts it, and when delivered', () {
    for (final status in [
      MessageStatus.submitted,
      MessageStatus.sent,
      MessageStatus.delivered,
    ]) {
      expect(describeMessageDelivery(_message(status))!.ticks, 2);
    }
  });

  test('accepted by the carrier never claims it was delivered', () {
    final info = describeMessageDelivery(_message(MessageStatus.submitted))!;
    expect(info.title, 'Sent');
    expect(info.explanation.toLowerCase(), contains('cannot show a delivered'));
    expect(
      describeMessageDelivery(_message(MessageStatus.delivered))!.title,
      'Delivered',
    );
  });

  test('an unconfirmed handoff is a single tick, not an error', () {
    final info = describeMessageDelivery(
      _message(MessageStatus.failed, errorCode: 'submission_uncertain'),
    )!;
    expect(info.stage, MessageDeliveryStage.unconfirmed);
    expect(info.ticks, 1);
  });

  test('failures and undelivered messages show a problem', () {
    expect(
      describeMessageDelivery(_message(MessageStatus.failed))!.ticks,
      isNull,
    );
    expect(
      describeMessageDelivery(_message(MessageStatus.undelivered))!.ticks,
      isNull,
    );
  });

  test('multi-part progress is described while sending', () {
    final info = describeMessageDelivery(
      _message(MessageStatus.sending, segmentCount: 4, segmentsSubmitted: 2),
    )!;
    expect(info.explanation, contains('2 of 4'));
  });

  test('received messages have no delivery status', () {
    expect(
      describeMessageDelivery(
        _message(MessageStatus.received, direction: MessageDirection.incoming),
      ),
      isNull,
    );
  });
}
