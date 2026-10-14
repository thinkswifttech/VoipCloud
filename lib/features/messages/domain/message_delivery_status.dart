import 'carrier_message.dart';

/// Where an outgoing text is on its way. Drives the ticks and the
/// "Message info" sheet, so both always agree.
enum MessageDeliveryStage {
  /// Only on this phone so far.
  sending,

  /// VoipCloud has it and is passing it to the carrier.
  withVoipCloud,

  /// The carrier accepted it for delivery.
  withCarrier,

  /// The carrier confirmed it reached the recipient.
  delivered,

  /// Passed to the carrier but the answer never came back.
  unconfirmed,

  /// The carrier could not deliver it.
  notDelivered,

  /// We could not send it.
  failed,
}

class MessageDeliveryInfo {
  const MessageDeliveryInfo({
    required this.stage,
    required this.title,
    required this.explanation,
  });

  final MessageDeliveryStage stage;
  final String title;
  final String explanation;

  /// 0 = clock, 1 = single tick, 2 = double tick, null = problem.
  int? get ticks => switch (stage) {
    MessageDeliveryStage.sending => 0,
    MessageDeliveryStage.withVoipCloud || MessageDeliveryStage.unconfirmed => 1,
    MessageDeliveryStage.withCarrier || MessageDeliveryStage.delivered => 2,
    MessageDeliveryStage.notDelivered || MessageDeliveryStage.failed => null,
  };
}

/// A message only exists under its client id until the server acknowledges it.
bool messageReachedServer(CarrierMessage message) =>
    message.id != message.clientId;

/// Plain-language status of an outgoing message. Returns null for received
/// messages.
MessageDeliveryInfo? describeMessageDelivery(CarrierMessage message) {
  if (message.direction == MessageDirection.incoming ||
      message.status == MessageStatus.received) {
    return null;
  }
  final parts = message.segmentCount;
  final multipart = parts > 1;
  return switch (message.status) {
    MessageStatus.received => null,
    MessageStatus.queued || MessageStatus.sending =>
      messageReachedServer(message)
          ? MessageDeliveryInfo(
              stage: MessageDeliveryStage.withVoipCloud,
              title: 'Received by VoipCloud',
              explanation: multipart
                  ? 'We have your message and are sending it in $parts parts '
                        '(${message.segmentsSubmitted} of $parts sent so far).'
                  : 'We have your message and are passing it to the carrier.',
            )
          : const MessageDeliveryInfo(
              stage: MessageDeliveryStage.sending,
              title: 'Sending',
              explanation:
                  'Your message is still on this phone. It goes out as soon '
                  'as there is a connection.',
            ),
    MessageStatus.submitted || MessageStatus.sent => MessageDeliveryInfo(
      stage: MessageDeliveryStage.withCarrier,
      title: 'Sent',
      explanation:
          'The carrier accepted your message${multipart ? ' ($parts parts)' : ''} '
          "and it is on its way. Carriers don't always confirm when a text "
          'arrives, so we cannot show a delivered notice.',
    ),
    MessageStatus.delivered => const MessageDeliveryInfo(
      stage: MessageDeliveryStage.delivered,
      title: 'Delivered',
      explanation: "The carrier confirmed it reached the recipient's phone.",
    ),
    MessageStatus.undelivered => const MessageDeliveryInfo(
      stage: MessageDeliveryStage.notDelivered,
      title: 'Not delivered',
      explanation:
          "The carrier couldn't deliver this message. Check the number and "
          'try again.',
    ),
    MessageStatus.failed when message.errorCode == 'submission_uncertain' =>
      const MessageDeliveryInfo(
        stage: MessageDeliveryStage.unconfirmed,
        title: 'Sent, waiting for confirmation',
        explanation:
            'We passed your message to the carrier but did not get an answer '
            "back. It has probably gone through. If the person says it didn't "
            'arrive, send it again.',
      ),
    MessageStatus.failed => MessageDeliveryInfo(
      stage: MessageDeliveryStage.failed,
      title: 'Not sent',
      explanation: message.canRetry
          ? "We couldn't send this message. Tap Retry to try again."
          : "We couldn't send this message.",
    ),
  };
}
