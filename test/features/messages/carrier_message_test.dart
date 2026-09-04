import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/features/messages/domain/carrier_message.dart';

void main() {
  test('parses an inbound server message and MMS metadata', () {
    final message = CarrierMessage.fromJson({
      'id': 'message-1',
      'direction': 'inbound',
      'from_e164': '+14165550101',
      'to_e164': '+14165550202',
      'body': 'Photo attached',
      'state': 'received',
      'created_at': '2026-08-10T18:25:31Z',
      'attachments': [
        {
          'id': 'attachment-1',
          'mime_type': 'image/jpeg',
          'file_name': 'photo.jpg',
          'size_bytes': 2048,
          'url': 'https://messaging.example.test/media/attachment-1',
        },
      ],
    }, localNumber: '+14165550202');

    expect(message.direction, MessageDirection.incoming);
    expect(message.remoteNumber, '+14165550101');
    expect(message.status, MessageStatus.received);
    expect(message.createdAt, DateTime.utc(2026, 8, 10, 18, 25, 31));
    expect(message.attachments.single.contentType, 'image/jpeg');
    expect(message.attachments.single.sizeBytes, 2048);
    expect(message.attachments.single.state, MessageAttachmentState.ready);
  });

  test('parses outbound delivery state and remote participant', () {
    final message = CarrierMessage.fromJson({
      'id': 'message-2',
      'direction': 'outbound',
      'from_e164': '+14165550202',
      'to_e164': '+14165550303',
      'body': 'Hello',
      'state': 'delivered',
      'created_at': '2026-08-10T18:26:00Z',
    }, localNumber: '+14165550202');

    expect(message.direction, MessageDirection.outgoing);
    expect(message.remoteNumber, '+14165550303');
    expect(message.status, MessageStatus.delivered);
  });

  test('keeps carrier submission distinct from sent and delivered', () {
    final message = CarrierMessage.fromJson({
      'id': 'message-3',
      'direction': 'outbound',
      'from_e164': '+14165550202',
      'to_e164': '+14165550303',
      'body': 'Accepted by carrier',
      'state': 'submitted',
      'created_at': '2026-08-10T18:27:00Z',
    }, localNumber: '+14165550202');

    expect(message.status, MessageStatus.submitted);
  });

  test('does not claim an unknown carrier state was sent', () {
    final message = CarrierMessage.fromJson({
      'id': 'message-unknown',
      'direction': 'outbound',
      'to_e164': '+14165550123',
      'state': 'provider_state_not_yet_normalized',
      'created_at': '2026-08-13T15:00:00Z',
    });

    expect(message.status, MessageStatus.queued);
  });

  test('only exposes retry for certain terminal SMS failures', () {
    CarrierMessage failed(String? errorCode) => CarrierMessage(
      id: 'message-failed',
      remoteNumber: '+14165550303',
      direction: MessageDirection.outgoing,
      text: 'Retry me',
      status: MessageStatus.failed,
      errorCode: errorCode,
      createdAt: DateTime.utc(2026, 8, 13),
    );

    expect(failed('provider_rejected').canRetry, isTrue);
    expect(failed('submission_uncertain').canRetry, isFalse);
    expect(
      CarrierMessage(
        id: 'failed-mms',
        remoteNumber: '+14165550303',
        direction: MessageDirection.outgoing,
        text: '',
        status: MessageStatus.failed,
        errorCode: 'provider_rejected',
        createdAt: DateTime.utc(2026, 8, 13),
        attachments: [
          MessageAttachment(
            id: 'ready-media',
            contentType: 'image/jpeg',
            state: MessageAttachmentState.ready,
            downloadUri: Uri.parse('/api/v1/messaging/media/ready-media'),
          ),
        ],
      ).canRetry,
      isTrue,
    );
    expect(
      CarrierMessage(
        id: 'message-inbound',
        remoteNumber: '+14165550303',
        direction: MessageDirection.incoming,
        text: 'Inbound',
        status: MessageStatus.failed,
        createdAt: DateTime.utc(2026, 8, 13),
      ).canRetry,
      isFalse,
    );
  });
}
