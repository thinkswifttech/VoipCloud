import 'package:flutter/services.dart';

class ProximityScreenControl {
  const ProximityScreenControl({
    MethodChannel channel = const MethodChannel('voipcloud/proximity'),
  }) : _channel = channel;

  final MethodChannel _channel;

  Future<void> setEnabled(bool enabled) async {
    try {
      await _channel.invokeMethod<void>('setEnabled', {'enabled': enabled});
    } on MissingPluginException {
      // Desktop and tests do not need mobile proximity behavior.
    }
  }
}
