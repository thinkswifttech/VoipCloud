import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import 'voip_platform_channel.dart';

Future<void> showAndroidBackgroundPermissionDialog(
  BuildContext context, {
  VoipPlatformChannel platformChannel = const VoipPlatformChannel(),
}) async {
  if (!Platform.isAndroid) {
    return;
  }

  final ignored = await platformChannel.isBatteryOptimizationIgnored();
  if (!context.mounted || ignored) {
    return;
  }

  final allow = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) {
      return AlertDialog(
        title: const Text('Allow background activity'),
        content: const Text(
          'To receive calls reliably when the app is in the background, '
          'Android needs permission to run without battery restrictions. '
          'On some devices you may also need to allow autostart in system settings.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Allow'),
          ),
        ],
      );
    },
  );

  if (allow == true) {
    await platformChannel.requestIgnoreBatteryOptimizations();
  }
}

Future<void> openAndroidBackgroundPermissionSettings({
  VoipPlatformChannel platformChannel = const VoipPlatformChannel(),
}) async {
  if (!Platform.isAndroid) {
    return;
  }
  await platformChannel.openBatteryOptimizationSettings();
}
