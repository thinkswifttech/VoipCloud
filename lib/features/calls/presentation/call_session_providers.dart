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

final callTransferModeProvider =
    NotifierProvider<CallTransferModeController, bool>(
      CallTransferModeController.new,
    );

class CallTransferModeController extends Notifier<bool> {
  @override
  bool build() => false;

  void begin() => state = true;

  void clear() => state = false;
}
