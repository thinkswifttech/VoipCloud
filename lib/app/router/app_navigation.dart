import 'route_names.dart';

List<String> appNavigationPaths({
  required bool showDirectory,
  required bool showCarrierMessaging,
}) {
  return [
    RoutePaths.dialer,
    if (showDirectory) RoutePaths.directory,
    RoutePaths.callHistory,
    RoutePaths.contacts,
    if (showCarrierMessaging) RoutePaths.messages,
  ];
}

int appNavigationIndexForLocation(
  String location,
  List<String> navigationPaths,
) {
  final index = navigationPaths.indexWhere(location.startsWith);
  return index < 0 ? 0 : index;
}
