import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import 'route_names.dart';

/// Routes carrier-message notification taps on every Firebase-supported
/// platform. Android also has a native bridge because its data-only message
/// notification is rendered before Flutter starts.
class MessagingNotificationListener {
  MessagingNotificationListener(this._router);

  static const _channel = MethodChannel('voipcloud/messaging_notifications');

  final GoRouter _router;
  final Set<String> _handledMessageIds = <String>{};
  StreamSubscription<RemoteMessage>? _firebaseTapSubscription;
  String? _pendingMessageId;

  Future<void> start() async {
    if (kIsWeb) return;
    _router.routeInformationProvider.addListener(_routeWhenReady);

    if (defaultTargetPlatform == TargetPlatform.android) {
      _channel.setMethodCallHandler(_handleMethodCall);
      try {
        final payload = await _channel.invokeMapMethod<String, dynamic>(
          'consumePendingNotification',
        );
        _receive(payload);
      } on MissingPluginException {
        // Native host support is absent in tests and older app builds.
      }
    }

    if (_supportsFirebaseMessaging && Firebase.apps.isNotEmpty) {
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        // The foreground app owns message and call presentation. PushKit calls
        // are still reported natively to CallKit as required by iOS; this only
        // suppresses ordinary Firebase alert, badge, and sound presentation.
        await FirebaseMessaging.instance
            .setForegroundNotificationPresentationOptions(
              alert: false,
              badge: false,
              sound: false,
            );
      } else if (defaultTargetPlatform == TargetPlatform.macOS) {
        await FirebaseMessaging.instance
            .setForegroundNotificationPresentationOptions(
              alert: true,
              badge: true,
              sound: true,
            );
      }
      _firebaseTapSubscription = FirebaseMessaging.onMessageOpenedApp.listen(
        (message) => _receive(message.data),
      );
      final initialMessage = await FirebaseMessaging.instance
          .getInitialMessage();
      _receive(initialMessage?.data);
    }
  }

  void dispose() {
    unawaited(_firebaseTapSubscription?.cancel());
    _firebaseTapSubscription = null;
    _router.routeInformationProvider.removeListener(_routeWhenReady);
    if (defaultTargetPlatform == TargetPlatform.android) {
      _channel.setMethodCallHandler(null);
    }
  }

  bool get _supportsFirebaseMessaging =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS;

  Future<Object?> _handleMethodCall(MethodCall call) async {
    if (call.method != 'notificationTapped') return null;
    final arguments = call.arguments;
    if (arguments is Map) {
      _receive(Map<String, dynamic>.from(arguments));
    }
    return true;
  }

  void _receive(Map<String, dynamic>? payload) {
    final messageId = '${payload?['message_id'] ?? ''}'.trim();
    if (messageId.isEmpty || !_handledMessageIds.add(messageId)) return;
    _pendingMessageId = messageId;
    _routeWhenReady();
  }

  void _routeWhenReady() {
    final messageId = _pendingMessageId;
    if (messageId == null) return;
    final path = _router.routeInformationProvider.value.uri.path;
    if (path == RoutePaths.splash || path.startsWith('/calls/')) return;
    _pendingMessageId = null;
    _router.go(
      Uri(
        path: RoutePaths.messages,
        queryParameters: {'message': messageId},
      ).toString(),
    );
  }
}
