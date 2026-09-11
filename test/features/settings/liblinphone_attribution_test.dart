import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/features/settings/presentation/liblinphone_attribution.dart';

void main() {
  testWidgets('shows Liblinphone attribution and public source links', (
    tester,
  ) async {
    Uri? openedUri;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LiblinphoneAttributionTile(
            externalUrlLauncher: (uri) async {
              openedUri = uri;
              return true;
            },
          ),
        ),
      ),
    );

    expect(find.text('Built with Liblinphone'), findsOneWidget);
    expect(find.textContaining('Belledonne Communications'), findsOneWidget);

    await tester.tap(find.text('Built with Liblinphone'));
    await tester.pumpAndSettle();

    expect(find.text('Open-source acknowledgements'), findsOneWidget);
    expect(find.text('GNU AGPLv3 license'), findsOneWidget);
    expect(find.text('Source code for this version'), findsOneWidget);
    expect(
      find.textContaining('redistribute it and/or modify it'),
      findsOneWidget,
    );
    expect(find.textContaining('provided without warranty'), findsOneWidget);
    expect(
      find.textContaining('not endorsed by Belledonne Communications'),
      findsOneWidget,
    );

    await tester.tap(find.text('Source code for this version'));
    await tester.pump();

    expect(openedUri, LiblinphoneAttributionTile.sourceUri);
  });
}
