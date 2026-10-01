import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logging/app_logger.dart';
import '../../sip/application/sip_service.dart';

import '../domain/call_direction.dart';
import '../domain/call_status.dart';
import '../domain/voip_call.dart';

/// True when the call should drive Dial in-call UI (not incoming ringing).
bool isInCallUiCall(VoipCall? call) {
  if (call == null) return false;
  if (call.direction == CallDirection.incoming &&
      call.status == CallStatus.ringing) {
    return false;
  }
  return switch (call.status) {
    CallStatus.ended || CallStatus.missed || CallStatus.failed => false,
    _ => true,
  };
}

enum CallTransferKind { blind, attended }

class CallTransferRequest {
  const CallTransferRequest({required this.kind, required this.originalCallId});

  final CallTransferKind kind;
  final String originalCallId;
}

class AttendedTransferSession {
  const AttendedTransferSession({
    required this.originalCallId,
    required this.destination,
    required this.destinationLabel,
  });

  final String originalCallId;
  final String destination;
  final String destinationLabel;
}

/// A manually held caller plus a new outgoing call is also a consultation.
/// Keep explicit workflows tied to their original caller; never reverse them
/// merely because the user has switched which call is displayed.
AttendedTransferSession? resolveConsultationTransferSession({
  required VoipCall displayedCall,
  required VoipCall? heldCall,
  required String destinationLabel,
  AttendedTransferSession? session,
}) {
  if (heldCall == null ||
      heldCall.id == displayedCall.id ||
      heldCall.status != CallStatus.held ||
      !{
        CallStatus.dialing,
        CallStatus.connecting,
        CallStatus.active,
      }.contains(displayedCall.status)) {
    return null;
  }
  if (session != null) {
    return session.originalCallId == heldCall.id ? session : null;
  }
  if (displayedCall.direction != CallDirection.outgoing) return null;
  return AttendedTransferSession(
    originalCallId: heldCall.id,
    destination: displayedCall.remoteUri,
    destinationLabel: destinationLabel,
  );
}

final callTransferModeProvider =
    NotifierProvider<CallTransferModeController, CallTransferRequest?>(
      CallTransferModeController.new,
    );

class CallTransferModeController extends Notifier<CallTransferRequest?> {
  @override
  CallTransferRequest? build() => null;

  void begin({required CallTransferKind kind, required String originalCallId}) {
    state = CallTransferRequest(kind: kind, originalCallId: originalCallId);
  }

  void clear() => state = null;

  /// Abandoning target selection restores only the original, sole held call.
  /// Successful consultation creation uses clear(), keeping the caller held.
  Future<void> cancelSelection(SipService service) async {
    final request = state;
    state = null;
    if (request?.kind != CallTransferKind.attended) return;
    final calls = service.liveCalls;
    if (calls.length != 1 ||
        calls.single.id != request!.originalCallId ||
        calls.single.status != CallStatus.held) {
      return;
    }
    try {
      await service.resume(request.originalCallId);
    } catch (error) {
      // Leave the real native held state visible so the user can retry Resume.
      AppLogger.warning(
        'Unable to resume caller after cancelling target selection: $error',
      );
    }
  }
}

final attendedTransferSessionProvider =
    NotifierProvider<
      AttendedTransferSessionController,
      AttendedTransferSession?
    >(AttendedTransferSessionController.new);

class AttendedTransferSessionController
    extends Notifier<AttendedTransferSession?> {
  @override
  AttendedTransferSession? build() => null;

  void begin(AttendedTransferSession session) => state = session;

  void clear() => state = null;
}
