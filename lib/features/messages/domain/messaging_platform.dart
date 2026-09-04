import 'package:flutter/foundation.dart';

import 'carrier_messaging_config.dart';

bool isCarrierMessagingSupported({bool? web, TargetPlatform? platform}) {
  if (web ?? kIsWeb) return false;
  return switch (platform ?? defaultTargetPlatform) {
    TargetPlatform.android ||
    TargetPlatform.iOS ||
    TargetPlatform.windows ||
    TargetPlatform.macOS => true,
    TargetPlatform.linux || TargetPlatform.fuchsia => false,
  };
}

bool isCarrierMessagingEnabled(
  CarrierMessagingConfig? config, {
  bool? web,
  TargetPlatform? platform,
}) =>
    config?.enabled == true &&
    isCarrierMessagingSupported(web: web, platform: platform);
