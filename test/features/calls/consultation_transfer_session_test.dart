import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/features/calls/domain/call_direction.dart';
import 'package:phone_app/features/calls/domain/call_status.dart';
import 'package:phone_app/features/calls/domain/voip_call.dart';
import 'package:phone_app/features/calls/presentation/call_session_providers.dart';

void main() {
  VoipCall call(
    String id,
    CallStatus status, {
    CallDirection direction = CallDirection.outgoing,
  }) => VoipCall(
    id: id,
    remoteUri: 'sip:$id@example.test',
    direction: direction,
    status: status,
    startedAt: DateTime.utc(2026),
  );

  final held = call(
    'original',
    CallStatus.held,
    direction: CallDirection.incoming,
  );
  const explicit = AttendedTransferSession(
    originalCallId: 'original',
    destination: '211',
    destinationLabel: 'Consultation',
  );

  test(
    'manual hold then dial resolves the original and consultation calls',
    () {
      final result = resolveConsultationTransferSession(
        displayedCall: call('consultation', CallStatus.active),
        heldCall: held,
        destinationLabel: 'Consultation',
      );
      expect(result?.originalCallId, 'original');
      expect(result?.destination, 'sip:consultation@example.test');
    },
  );

  test('dialing consultation retains its transfer workflow', () {
    expect(
      resolveConsultationTransferSession(
        displayedCall: call('consultation', CallStatus.dialing),
        heldCall: held,
        destinationLabel: 'Consultation',
        session: explicit,
      ),
      same(explicit),
    );
  });

  test('swapping calls cannot reverse an explicit transfer', () {
    expect(
      resolveConsultationTransferSession(
        displayedCall: call('original', CallStatus.active),
        heldCall: call('consultation', CallStatus.held),
        destinationLabel: 'Original',
        session: explicit,
      ),
      isNull,
    );
  });

  test('an incoming waiting call is not inferred as a consultation', () {
    expect(
      resolveConsultationTransferSession(
        displayedCall: call(
          'waiting',
          CallStatus.active,
          direction: CallDirection.incoming,
        ),
        heldCall: held,
        destinationLabel: 'Waiting',
      ),
      isNull,
    );
  });

  test('no held caller or ended consultation cannot offer transfer', () {
    expect(
      resolveConsultationTransferSession(
        displayedCall: call('consultation', CallStatus.active),
        heldCall: null,
        destinationLabel: 'Consultation',
      ),
      isNull,
    );
    expect(
      resolveConsultationTransferSession(
        displayedCall: call('consultation', CallStatus.ended),
        heldCall: held,
        destinationLabel: 'Consultation',
        session: explicit,
      ),
      isNull,
    );
  });
}
