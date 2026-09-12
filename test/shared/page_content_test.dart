import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/shared/widgets/page_content.dart';

void main() {
  const childKey = Key('content');

  testWidgets(
    'uses expanded list width on a wide desktop window',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1600, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: PageContent(
              maxWidth: 680,
              desktopMaxWidth: 1120,
              scrollable: false,
              child: SizedBox(key: childKey),
            ),
          ),
        ),
      );

      expect(tester.getSize(find.byKey(childKey)).width, 1120);
    },
    variant: const TargetPlatformVariant({TargetPlatform.windows}),
  );

  testWidgets(
    'keeps compact list width on non-desktop platforms',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1600, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: PageContent(
              maxWidth: 680,
              desktopMaxWidth: 1120,
              scrollable: false,
              child: SizedBox(key: childKey),
            ),
          ),
        ),
      );

      expect(tester.getSize(find.byKey(childKey)).width, 680);
    },
    variant: const TargetPlatformVariant({TargetPlatform.android}),
  );
}
