import 'package:flutter/services.dart';

class DefaultCommunicationApps {
  const DefaultCommunicationApps({
    MethodChannel channel = const MethodChannel(
      'voipcloud/external_communication_intents',
    ),
  }) : _channel = channel;

  final MethodChannel _channel;

  Future<void> openSettings() =>
      _channel.invokeMethod<void>('openDefaultAppsSettings');
}
