import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

class MessagingPushRegistration {
  const MessagingPushRegistration({
    required this.provider,
    required this.token,
    required this.environment,
  });

  final String provider;
  final String token;
  final String environment;
}

class MessagingPushTokenService {
  const MessagingPushTokenService();

  Future<MessagingPushRegistration?> load() async {
    if (kIsWeb || Firebase.apps.isEmpty) return null;
    if (defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS) {
      return null;
    }

    final messaging = FirebaseMessaging.instance;
    final settings = await messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      provisional: true,
    );
    if (settings.authorizationStatus == AuthorizationStatus.denied ||
        settings.authorizationStatus == AuthorizationStatus.notDetermined) {
      return null;
    }

    if (defaultTargetPlatform == TargetPlatform.android) {
      final token = (await messaging.getToken())?.trim() ?? '';
      return token.isEmpty
          ? null
          : MessagingPushRegistration(
              provider: 'fcm',
              token: token,
              environment: 'production',
            );
    }

    final token = (await messaging.getAPNSToken())?.trim() ?? '';
    if (token.isEmpty) return null;
    return MessagingPushRegistration(
      provider: 'apns',
      token: token,
      environment: kReleaseMode ? 'production' : 'sandbox',
    );
  }
}
