import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/app/router/app_navigation.dart';
import 'package:phone_app/app/router/route_names.dart';

void main() {
  test('omits directory and keeps destination indexes aligned', () {
    final paths = appNavigationPaths(
      showDirectory: false,
      showCarrierMessaging: false,
    );

    expect(paths, [
      RoutePaths.dialer,
      RoutePaths.callHistory,
      RoutePaths.contacts,
    ]);
    expect(appNavigationIndexForLocation(RoutePaths.callHistory, paths), 1);
    expect(appNavigationIndexForLocation(RoutePaths.contacts, paths), 2);
  });

  test('includes provisioned optional destinations in navigation order', () {
    final paths = appNavigationPaths(
      showDirectory: true,
      showCarrierMessaging: true,
    );

    expect(paths, [
      RoutePaths.dialer,
      RoutePaths.directory,
      RoutePaths.callHistory,
      RoutePaths.contacts,
      RoutePaths.messages,
    ]);
    expect(appNavigationIndexForLocation(RoutePaths.directory, paths), 1);
    expect(appNavigationIndexForLocation(RoutePaths.messages, paths), 4);
  });
}
