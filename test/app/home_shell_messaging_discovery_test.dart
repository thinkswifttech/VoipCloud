import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/app/router/home_shell.dart';
import 'package:phone_app/features/call_history/presentation/call_history_providers.dart';
import 'package:phone_app/features/messages/presentation/messages_providers.dart';
import 'package:phone_app/features/session/domain/app_session.dart';
import 'package:phone_app/features/session/presentation/session_controller.dart';

void main() {
  test(
    'badge provider starts messaging discovery before entitlement is known',
    () {
      _TrackingMessagesController.buildCount = 0;
      final container = ProviderContainer(
        overrides: [
          sessionControllerProvider.overrideWith(_EmptySessionController.new),
          missedCallCountProvider.overrideWith(_ZeroMissedCalls.new),
          messagesControllerProvider.overrideWith(
            _TrackingMessagesController.new,
          ),
        ],
      );
      addTearDown(container.dispose);

      final counts = container.read(appBadgeCountsProvider);

      expect(counts, (missedCalls: 0, unreadMessages: 0));
      expect(_TrackingMessagesController.buildCount, 1);
    },
  );
}

class _EmptySessionController extends SessionController {
  @override
  Future<AppSession?> build() async => null;
}

class _ZeroMissedCalls extends MissedCallCountController {
  @override
  Future<int> build() async => 0;
}

class _TrackingMessagesController extends MessagesController {
  static var buildCount = 0;

  @override
  MessagesState build() {
    buildCount += 1;
    return const MessagesState();
  }
}
