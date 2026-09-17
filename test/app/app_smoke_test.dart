import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/app/app.dart';
import 'package:phone_app/core/errors/app_exception.dart';
import 'package:phone_app/core/storage/secure_storage_service.dart';
import 'package:phone_app/core/storage/storage_providers.dart';

void main() {
  testWidgets('app boots to provisioning when no session exists', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          secureStorageProvider.overrideWithValue(
            InMemorySecureStorageService(),
          ),
        ],
        child: const SoftphoneApp(),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Set up your calling app'), findsOneWidget);
    expect(find.text('Activate'), findsOneWidget);
  });

  testWidgets('storage failure never masquerades as an unprovisioned app', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          secureStorageProvider.overrideWithValue(_UnavailableStorage()),
        ],
        child: const SoftphoneApp(),
      ),
    );

    // Startup intentionally keeps an indeterminate progress animation alive
    // while secure storage is unavailable, so advance past the retry window
    // instead of waiting for every animation to settle.
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();

    expect(
      find.text('Your saved account is temporarily unavailable'),
      findsOneWidget,
    );
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Set up your calling app'), findsNothing);
  });
}

class _UnavailableStorage implements SecureStorageService {
  @override
  Future<String?> read(String key) {
    throw const StorageException(message: 'Keychain temporarily locked');
  }

  @override
  Future<void> write(String key, String value) async {}

  @override
  Future<void> delete(String key) async {}

  @override
  Future<void> deleteAll() async {}
}
