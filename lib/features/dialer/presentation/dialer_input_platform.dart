import 'package:flutter/foundation.dart';

import '../../../shared/platform/desktop_platform.dart';

bool supportsDesktopDialerKeyboard({bool? web, TargetPlatform? platform}) {
  return isSupportedDesktopPlatform(web: web, platform: platform);
}

String? dtmfCharacterFromKeyboard(String? character) {
  if (character == null || !RegExp(r'^[0-9*#]$').hasMatch(character)) {
    return null;
  }
  return character;
}
