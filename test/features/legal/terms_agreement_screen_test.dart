import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/app/theme/app_theme.dart';
import 'package:phone_app/features/legal/presentation/terms_agreement_screen.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('shows the complete agreement in ${brightness.name} theme', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: AppTheme.lightTheme(),
            darkTheme: AppTheme.darkTheme(),
            themeMode: brightness == Brightness.dark
                ? ThemeMode.dark
                : ThemeMode.light,
            home: const TermsAgreementScreen(
              termsText: 'ThinkSwift Master Services Agreement\nTest terms',
            ),
          ),
        ),
      );
      // SelectableText keeps a cursor timer alive, so wait only for the asset
      // future instead of requiring the entire widget tree to become idle.
      await tester.pump();
      for (var attempt = 0; attempt < 20; attempt++) {
        final checkbox = tester.widget<Checkbox>(find.byType(Checkbox));
        if (checkbox.onChanged != null) break;
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(find.text('Terms of Service'), findsOneWidget);
      expect(
        find.textContaining('ThinkSwift Master Services Agreement'),
        findsWidgets,
      );
      expect(find.text('Accept and continue'), findsOneWidget);
      expect(find.text('Decline and reset'), findsOneWidget);

      final accept = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Accept and continue'),
      );
      expect(accept.onPressed, isNull);

      final checkbox = tester.widget<Checkbox>(find.byType(Checkbox));
      expect(checkbox.onChanged, isNotNull);

      await tester.tap(find.byType(Checkbox));
      await tester.pump();

      final enabledAccept = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Accept and continue'),
      );
      expect(enabledAccept.onPressed, isNotNull);
    });
  }
}
