import 'package:flutter/foundation.dart';

/// True only for the native desktop builds that use mouse/keyboard-first UI.
///
/// Linux is intentionally excluded until a supported native SIP host exists.
bool isSupportedDesktopPlatform({bool? web, TargetPlatform? platform}) {
  if (web ?? kIsWeb) return false;
  return switch (platform ?? defaultTargetPlatform) {
    TargetPlatform.windows || TargetPlatform.macOS => true,
    TargetPlatform.android ||
    TargetPlatform.iOS ||
    TargetPlatform.linux ||
    TargetPlatform.fuchsia => false,
  };
}
