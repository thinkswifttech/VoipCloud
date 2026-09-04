import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/failure.dart';
import '../../../core/network/dio_provider.dart';
import '../../../core/storage/storage_providers.dart';
import '../data/api_auth_repository.dart';
import '../domain/auth_repository.dart';
import '../domain/auth_session.dart';
import '../domain/user.dart';

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  return ApiAuthRepository(
    client: ref.watch(appClientProvider),
    storage: ref.watch(secureStorageProvider),
  );
});

final authControllerProvider =
    AsyncNotifierProvider<AuthController, AuthSession?>(AuthController.new);

final currentUserProvider = Provider<AsyncValue<User?>>((ref) {
  return ref.watch(authControllerProvider).whenData((session) => session?.user);
});

class AuthController extends AsyncNotifier<AuthSession?> {
  @override
  Future<AuthSession?> build() {
    return ref.watch(authRepositoryProvider).getSession();
  }

  Future<Failure?> login({
    required String email,
    required String password,
  }) async {
    state = const AsyncLoading();
    final result = await AsyncValue.guard(
      () => ref
          .read(authRepositoryProvider)
          .login(email: email, password: password),
    );
    state = result;
    return result.hasError
        ? Failure.fromException(result.error!, result.stackTrace)
        : null;
  }

  Future<void> logout() async {
    await ref.read(authRepositoryProvider).logout();
    state = const AsyncData(null);
  }
}
