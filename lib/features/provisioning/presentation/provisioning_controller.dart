import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/failure.dart';
import '../../../core/config/config_providers.dart';
import '../../../core/network/dio_provider.dart';
import '../../session/presentation/session_controller.dart';
import '../data/provisioning_repository.dart';
import '../domain/provisioning_activation_input.dart';

final provisioningRepositoryProvider = Provider<ProvisioningRepository>((ref) {
  return ProvisioningRepository(
    ref.watch(appClientProvider),
    ref.watch(appConfigProvider),
  );
});

final provisioningControllerProvider =
    NotifierProvider<ProvisioningController, ProvisioningState>(
      ProvisioningController.new,
    );

class ProvisioningState {
  const ProvisioningState({this.isLoading = false, this.failure});

  final bool isLoading;
  final Failure? failure;
}

class ProvisioningController extends Notifier<ProvisioningState> {
  @override
  ProvisioningState build() => const ProvisioningState();

  Future<bool> activate(String input) async {
    final provisioningInput = parseProvisioningInput(input);
    if (provisioningInput == null) {
      state = const ProvisioningState(
        failure: Failure(
          userMessage: 'Enter a provisioning link or scan the QR code again.',
        ),
      );
      return false;
    }

    state = const ProvisioningState(isLoading: true);
    final result = await AsyncValue.guard(() async {
      final device = await ref
          .read(deviceInfoRepositoryProvider)
          .getDeviceInfo();
      final session = await ref
          .read(provisioningRepositoryProvider)
          .activate(input: provisioningInput, device: device);
      await ref
          .read(sessionControllerProvider.notifier)
          .stageProvisionedSession(session);
      return session;
    });

    if (result.hasError) {
      state = ProvisioningState(
        failure: Failure.fromException(result.error!, result.stackTrace),
      );
      return false;
    }

    state = const ProvisioningState();
    return true;
  }
}
