import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/core/storage/secure_storage_service.dart';
import 'package:phone_app/features/legal/data/terms_acceptance_repository.dart';

void main() {
  test(
    'new provisioning remains gated until current terms are accepted',
    () async {
      final repository = TermsAcceptanceRepository(
        InMemorySecureStorageService(),
      );

      expect(await repository.isPending(), isFalse);

      await repository.markPending();
      expect(await repository.isPending(), isTrue);

      await repository.accept(version: '2026-08-11', sha256: 'a' * 64);
      expect(await repository.isPending(), isFalse);
    },
  );

  test('clearing acceptance removes a pending provisioning gate', () async {
    final repository = TermsAcceptanceRepository(
      InMemorySecureStorageService(),
    );

    await repository.markPending();
    await repository.clear();

    expect(await repository.isPending(), isFalse);
  });
}
