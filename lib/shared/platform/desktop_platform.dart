import 'package:flutter/foundation.dart';

bool isSupportedDesktopPlatform({
  bool? web,
  TargetPlatform? platform,
}) {
  if (web ?? kIsWeb) return false;
  return switch (platform ?? defaultTargetPlatform) {
    TargetPlatform.windows ||
    TargetPlatform.macOS ||
    TargetPlatform.linux => true,
    _ => false,
  };
}

bool get isDesktopPlatform => isSupportedDesktopPlatform();
