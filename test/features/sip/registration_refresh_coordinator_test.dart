import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/features/sip/application/registration_refresh_coordinator.dart';

void main() {
  group('RegistrationRefreshCoordinator', () {
    test('refreshes a registered account on foreground resume', () async {
      var refreshes = 0;
      final coordinator = RegistrationRefreshCoordinator(
        canRegister: () => true,
        hasActiveCall: () async => false,
        refresh: () async => refreshes++,
      );

      await coordinator.request(RegistrationRefreshReason.foregroundResume);

      expect(refreshes, 1);
    });

    test('coalesces rapid lifecycle and connectivity events', () async {
      var now = DateTime(2026, 9, 1, 12);
      var refreshes = 0;
      final coordinator = RegistrationRefreshCoordinator(
        canRegister: () => true,
        hasActiveCall: () async => false,
        refresh: () async => refreshes++,
        now: () => now,
      );

      await coordinator.request(RegistrationRefreshReason.foregroundResume);
      now = now.add(const Duration(seconds: 5));
      await coordinator.request(RegistrationRefreshReason.connectivityRestored);

      expect(refreshes, 1);
    });

    test('joins concurrent refresh requests', () async {
      final completer = Completer<void>();
      var refreshes = 0;
      final coordinator = RegistrationRefreshCoordinator(
        canRegister: () => true,
        hasActiveCall: () async => false,
        refresh: () {
          refreshes++;
          return completer.future;
        },
      );

      final first = coordinator.request(
        RegistrationRefreshReason.foregroundResume,
      );
      final second = coordinator.request(
        RegistrationRefreshReason.connectivityRestored,
      );
      completer.complete();
      await Future.wait([first, second]);

      expect(refreshes, 1);
    });

    test('defers refresh during a call and retries after it ends', () async {
      var activeCall = true;
      var refreshes = 0;
      final coordinator = RegistrationRefreshCoordinator(
        canRegister: () => true,
        hasActiveCall: () async => activeCall,
        refresh: () async => refreshes++,
      );

      await coordinator.request(RegistrationRefreshReason.foregroundResume);
      expect(refreshes, 0);

      activeCall = false;
      await coordinator.retryAfterCallEnded();
      expect(refreshes, 1);
    });

    test('does nothing after logout or account blocking', () async {
      var refreshes = 0;
      final coordinator = RegistrationRefreshCoordinator(
        canRegister: () => false,
        hasActiveCall: () async => false,
        refresh: () async => refreshes++,
      );

      await coordinator.request(RegistrationRefreshReason.foregroundResume);

      expect(refreshes, 0);
    });
  });
}
