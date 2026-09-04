import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/logging/app_logger.dart';

const windowsTaskbarPinOfferArgument = '--offer-taskbar-pin';

bool shouldOfferWindowsTaskbarPin({
  required List<String> commandLineArguments,
  bool? web,
  TargetPlatform? platform,
}) {
  if (web ?? kIsWeb) return false;
  return (platform ?? defaultTargetPlatform) == TargetPlatform.windows &&
      commandLineArguments.contains(windowsTaskbarPinOfferArgument);
}

class WindowsTaskbarPinOffer extends StatefulWidget {
  const WindowsTaskbarPinOffer({
    required this.commandLineArguments,
    required this.child,
    super.key,
  });

  final List<String> commandLineArguments;
  final Widget child;

  @override
  State<WindowsTaskbarPinOffer> createState() => _WindowsTaskbarPinOfferState();
}

class _WindowsTaskbarPinOfferState extends State<WindowsTaskbarPinOffer> {
  static const _channel = MethodChannel('voipcloud/windows_taskbar');

  bool _visible = false;
  bool _requesting = false;

  @override
  void initState() {
    super.initState();
    if (shouldOfferWindowsTaskbarPin(
      commandLineArguments: widget.commandLineArguments,
    )) {
      unawaited(_checkAvailability());
    }
  }

  Future<void> _checkAvailability() async {
    try {
      final available =
          await _channel.invokeMethod<bool>('canRequestPin') ?? false;
      if (mounted && available) setState(() => _visible = true);
    } on PlatformException catch (error, stackTrace) {
      AppLogger.warning(
        'Taskbar pin offer availability check failed',
        data: error.code,
      );
      AppLogger.debug('Taskbar pin availability stack', data: stackTrace);
    }
  }

  Future<void> _requestPin() async {
    if (_requesting) return;
    setState(() => _requesting = true);
    try {
      final pinned = await _channel.invokeMethod<bool>('requestPin') ?? false;
      AppLogger.info('Taskbar pin request completed', data: pinned);
    } on PlatformException catch (error, stackTrace) {
      AppLogger.warning('Taskbar pin request failed', data: error.code);
      AppLogger.debug('Taskbar pin request stack', data: stackTrace);
    } finally {
      if (mounted) {
        setState(() {
          _requesting = false;
          _visible = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible) return widget.child;

    return Column(
      children: [
        MaterialBanner(
          content: const Text(
            'Keep VoipCloud within reach by pinning it to your taskbar.',
          ),
          leading: const Icon(Icons.push_pin_outlined),
          actions: [
            TextButton(
              onPressed: _requesting
                  ? null
                  : () => setState(() => _visible = false),
              child: const Text('Not now'),
            ),
            FilledButton(
              onPressed: _requesting ? null : _requestPin,
              child: Text(_requesting ? 'Requesting…' : 'Pin to taskbar'),
            ),
          ],
        ),
        Expanded(child: widget.child),
      ],
    );
  }
}
