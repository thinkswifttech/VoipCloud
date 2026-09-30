import 'package:flutter_riverpod/flutter_riverpod.dart';

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
