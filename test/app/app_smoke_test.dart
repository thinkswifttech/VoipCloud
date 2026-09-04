import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/app/app.dart';
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
}
