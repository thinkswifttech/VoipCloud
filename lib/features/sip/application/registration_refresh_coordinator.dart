import 'dart:async';

import '../../../core/logging/app_logger.dart';

enum RegistrationRefreshReason {
  foregroundResume,
  connectivityRestored,
  deferredUntilCallEnded,
}

/// Coalesces lifecycle-driven SIP REGISTER refreshes.
///
/// Liblinphone owns normal lease renewal. This coordinator only covers events
/// that can invalidate the network path (resume and connectivity recovery), so
/// it deliberately has no periodic timer.
class RegistrationRefreshCoordinator {
  RegistrationRefreshCoordinator({
    required bool Function() canRegister,
    required Future<bool> Function() hasActiveCall,
    required Future<void> Function() refresh,
    DateTime Function()? now,
    this.minimumInterval = const Duration(seconds: 30),
  }) : _canRegister = canRegister,
       _hasActiveCall = hasActiveCall,
       _refresh = refresh,
       _now = now ?? DateTime.now;

  final bool Function() _canRegister;
  final Future<bool> Function() _hasActiveCall;
  final Future<void> Function() _refresh;
  final DateTime Function() _now;
  final Duration minimumInterval;

  Future<void>? _inFlight;
  DateTime? _lastStartedAt;
  bool _deferredForCall = false;

  Future<void> request(RegistrationRefreshReason reason) {
    final current = _inFlight;
    if (current != null) return current;

    final operation = _request(reason);
    _inFlight = operation;
    return operation.whenComplete(() {
      if (identical(_inFlight, operation)) {
        _inFlight = null;
      }
    });
  }

  Future<void> retryAfterCallEnded() async {
    if (!_deferredForCall) return;
    _deferredForCall = false;
    await request(RegistrationRefreshReason.deferredUntilCallEnded);
  }

  Future<void> _request(RegistrationRefreshReason reason) async {
    if (!_canRegister()) {
      _deferredForCall = false;
      return;
    }

    if (await _hasActiveCall()) {
      _deferredForCall = true;
      AppLogger.debug(
        'Deferred SIP registration refresh while a call is active '
        'reason=${reason.name}',
      );
      return;
    }

    final now = _now();
    final lastStartedAt = _lastStartedAt;
    if (lastStartedAt != null &&
        now.difference(lastStartedAt) < minimumInterval) {
      AppLogger.debug(
        'Coalesced SIP registration refresh reason=${reason.name}',
      );
      return;
    }

    _lastStartedAt = now;
    AppLogger.info('Refreshing SIP registration reason=${reason.name}');
    await _refresh();
  }
}
