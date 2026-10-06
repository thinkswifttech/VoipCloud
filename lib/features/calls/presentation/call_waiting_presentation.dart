import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../session/presentation/session_controller.dart';
import '../domain/call_direction.dart';
import '../domain/call_status.dart';
import '../domain/voip_call.dart';
import 'call_session_providers.dart';

/// Presentation only: choosing a screen must never change the native call.
VoipCall? selectDisplayedCall(VoipCall? primary, List<VoipCall>? calls) {
  if (calls == null) return isInCallUiCall(primary) ? primary : null;
  for (final call in calls) {
    if (call.id == primary?.id && isInCallUiCall(call)) return call;
  }
  for (final status in [
    CallStatus.active,
    CallStatus.connecting,
    CallStatus.dialing,
    CallStatus.held,
    CallStatus.ringing,
  ]) {
    for (final call in calls) {
      if (call.status == status && isInCallUiCall(call)) return call;
    }
  }
  return null;
}

VoipCall? selectWaitingCall(List<VoipCall> calls, {String? excludingId}) {
  VoipCall? waiting;
  for (final call in calls) {
    if (call.id == excludingId ||
        call.direction != CallDirection.incoming ||
        call.status != CallStatus.ringing) {
      continue;
    }
    if (waiting == null || call.startedAt.isBefore(waiting.startedAt)) {
      waiting = call;
    }
  }
  return waiting;
}

final displayedInCallProvider = Provider<VoipCall?>(
  (ref) => selectDisplayedCall(
    ref.watch(activeCallProvider).value,
    ref.watch(liveCallsProvider).value,
  ),
);

/// Kept only for the current ringing episode, never stored across sessions.
final callWaitingPresentationProvider =
    NotifierProvider<CallWaitingPresentationController, Set<String>>(
      CallWaitingPresentationController.new,
    );

class CallWaitingPresentationController extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  void returnToCall(String waitingId) => state = {...state, waitingId};
  void showWaiting(String waitingId) => state = {...state}..remove(waitingId);

  void reconcile(List<VoipCall> calls) {
    final ringing = calls
        .where(
          (call) =>
              call.direction == CallDirection.incoming &&
              call.status == CallStatus.ringing,
        )
        .map((call) => call.id)
        .toSet();
    final retained = calls.any(isInCallUiCall)
        ? state.intersection(ringing)
        : <String>{};
    if (retained.length != state.length) state = retained;
  }
}
