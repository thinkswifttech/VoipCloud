import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/shared/widgets/app_modal_bottom_sheet.dart';

void main() {
  testWidgets('desktop sheets include a working close button', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await tester.pumpWidget(const _SheetTestApp());

    await tester.tap(find.text('Open sheet'));
    await tester.pumpAndSettle();

    expect(find.text('Sheet content'), findsOneWidget);
    expect(find.byTooltip('Close'), findsOneWidget);

    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();

    expect(find.text('Sheet content'), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('mobile sheets keep their existing chrome', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await tester.pumpWidget(const _SheetTestApp());

    await tester.tap(find.text('Open sheet'));
    await tester.pumpAndSettle();

    expect(find.text('Sheet content'), findsOneWidget);
    expect(find.byTooltip('Close'), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });
}

class _SheetTestApp extends StatelessWidget {
  const _SheetTestApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showAppModalBottomSheet<void>(
              context: context,
              builder: (_) => const Padding(
                padding: EdgeInsets.all(24),
                child: Text('Sheet content'),
              ),
            ),
            child: const Text('Open sheet'),
          ),
        ),
      ),
    );
  }
}
