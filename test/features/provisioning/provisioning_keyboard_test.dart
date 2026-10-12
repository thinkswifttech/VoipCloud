import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/features/provisioning/presentation/provisioning_screen.dart';

void main() {
  testWidgets('setup-link Activate stays above the mobile keyboard', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 700);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: ProvisioningScreen())),
    );
    await tester.tap(find.text('Setup link').last);
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byType(TextFormField));
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();

    final activate = find.byKey(const ValueKey('activate-setup-link'));
    expect(activate, findsOneWidget);
    expect(tester.getBottomRight(activate).dy, lessThanOrEqualTo(400));
    debugDefaultTargetPlatformOverride = null;
  });
}
