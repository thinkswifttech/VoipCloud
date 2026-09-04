import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/dialer/presentation/dialer_controller.dart';
import '../../features/messages/domain/messaging_platform.dart';
import '../../features/session/presentation/session_controller.dart';
import 'route_names.dart';

/// Routes phone numbers supplied by the operating system's default calling
/// and messaging surfaces. The destination is only populated; calls and
/// messages still require an explicit confirmation inside VoipCloud.
class ExternalCommunicationIntentListener extends ConsumerStatefulWidget {
  const ExternalCommunicationIntentListener({
    required this.router,
    required this.child,
    super.key,
  });

  final GoRouter router;
  final Widget child;

  @override
  ConsumerState<ExternalCommunicationIntentListener> createState() =>
      _ExternalCommunicationIntentListenerState();
}

class _ExternalCommunicationIntentListenerState
    extends ConsumerState<ExternalCommunicationIntentListener> {
  static const _channel = MethodChannel(
    'voipcloud/external_communication_intents',
  );

  _ExternalCommunicationIntent? _pending;
  final Set<String> _handledIntentIds = <String>{};

  bool get _isSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);

  @override
  void initState() {
    super.initState();
    if (!_isSupported) return;
    widget.router.routeInformationProvider.addListener(_routeWhenReady);
    _channel.setMethodCallHandler(_handleMethodCall);
    unawaited(_consumePendingNativeIntent());
  }

  @override
  void didUpdateWidget(
    covariant ExternalCommunicationIntentListener oldWidget,
  ) {
    super.didUpdateWidget(oldWidget);
    if (!_isSupported || identical(oldWidget.router, widget.router)) return;
    oldWidget.router.routeInformationProvider.removeListener(_routeWhenReady);
    widget.router.routeInformationProvider.addListener(_routeWhenReady);
  }

  @override
  void dispose() {
    if (_isSupported) {
      widget.router.routeInformationProvider.removeListener(_routeWhenReady);
      _channel.setMethodCallHandler(null);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(sessionControllerProvider, (_, _) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _routeWhenReady());
    });
    return widget.child;
  }

  Future<void> _consumePendingNativeIntent() async {
    try {
      final payload = await _channel.invokeMapMethod<String, dynamic>(
        'consumePendingIntent',
      );
      _receive(payload);
    } on MissingPluginException {
      // Native support is absent in tests and older installed builds.
    }
  }

  Future<Object?> _handleMethodCall(MethodCall call) async {
    if (call.method != 'externalCommunicationIntent') return null;
    final arguments = call.arguments;
    if (arguments is Map) {
      _receive(Map<String, dynamic>.from(arguments));
    }
    return true;
  }

  void _receive(Map<String, dynamic>? payload) {
    final intent = _ExternalCommunicationIntent.fromPayload(payload);
    if (intent == null) return;
    _pending = intent;
    _routeWhenReady();
  }

  void _routeWhenReady() {
    if (!mounted) return;
    final intent = _pending;
    if (intent == null) return;

    final path = widget.router.routeInformationProvider.value.uri.path;
    final session = ref.read(sessionControllerProvider).value;
    if (session == null ||
        path == RoutePaths.splash ||
        path.startsWith('/calls/')) {
      return;
    }

    _pending = null;
    if (!_handledIntentIds.add(intent.id)) return;
    if (intent.action == _ExternalCommunicationAction.message) {
      if (isCarrierMessagingEnabled(session.carrierMessaging)) {
        widget.router.go(
          Uri(
            path: RoutePaths.messages,
            queryParameters: {'to': intent.destination},
          ).toString(),
        );
      } else {
        unawaited(_openSystemMessageFallback(intent.destination));
      }
      return;
    }

    ref
        .read(dialerControllerProvider.notifier)
        .setDestination(intent.destination);
    widget.router.go(RoutePaths.dialer);
  }

  Future<void> _openSystemMessageFallback(String destination) async {
    try {
      await _channel.invokeMethod<void>('openSystemMessageFallback', {
        'destination': destination,
      });
    } on PlatformException {
      // The system Messages app may be unavailable or restricted.
    }
  }
}

enum _ExternalCommunicationAction { call, message }

class _ExternalCommunicationIntent {
  const _ExternalCommunicationIntent({
    required this.id,
    required this.action,
    required this.destination,
  });

  static _ExternalCommunicationIntent? fromPayload(
    Map<String, dynamic>? payload,
  ) {
    final id = '${payload?['id'] ?? ''}'.trim();
    final destination = '${payload?['destination'] ?? ''}'.trim();
    final action = switch ('${payload?['action'] ?? ''}'.trim()) {
      'call' => _ExternalCommunicationAction.call,
      'message' => _ExternalCommunicationAction.message,
      _ => null,
    };
    if (id.isEmpty ||
        action == null ||
        destination.isEmpty ||
        destination.length > 128) {
      return null;
    }
    return _ExternalCommunicationIntent(
      id: id,
      action: action,
      destination: destination,
    );
  }

  final String id;
  final _ExternalCommunicationAction action;
  final String destination;
}
