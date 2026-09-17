import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../session/domain/app_session.dart';
import '../../session/presentation/session_controller.dart';

final appStartupControllerProvider =
    AsyncNotifierProvider<AppStartupController, AppSession?>(
      AppStartupController.new,
    );

class AppStartupController extends AsyncNotifier<AppSession?> {
  @override
  Future<AppSession?> build() async {
    return null;
  }

  Future<AppSession?> restore() async {
    state = const AsyncLoading();
    final result = await AsyncValue.guard(
      () => ref.read(sessionControllerProvider.notifier).restoreAndRefresh(),
    );
    state = result;
    if (result.hasError) {
      Error.throwWithStackTrace(
        result.error!,
        result.stackTrace ?? StackTrace.current,
      );
    }
    return result.value;
  }
}
