import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../../core/logging/app_logger.dart';
import '../domain/sip_push_config.dart';

class SipPushTokenService {
  const SipPushTokenService({
    MethodChannel channel = const MethodChannel('voipcloud/push'),
  }) : _channel = channel;

  final MethodChannel _channel;

  Future<SipPushConfig?> getPushConfig() async {
    if (kIsWeb) {
      return null;
    }
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => _androidFcmConfig(),
      TargetPlatform.iOS => _iosVoipConfig(),
      _ => null,
    };
  }

  Future<SipPushConfig?> _androidFcmConfig() async {
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token == null || token.trim().isEmpty) {
        return null;
      }
      final projectId = Firebase.apps.isEmpty
          ? null
          : Firebase.app().options.projectId;
      final senderId = Firebase.apps.isEmpty
          ? null
          : Firebase.app().options.messagingSenderId;
      return SipPushConfig(
        provider: 'fcm',
        token: token,
        param: senderId?.trim().isNotEmpty == true ? senderId : projectId,
        bundleId: const String.fromEnvironment(
          'APP_BUNDLE_ID',
          defaultValue: 'com.thinkswift.softphoneapp',
        ),
      );
    } catch (error, stackTrace) {
      AppLogger.error(
        'Android FCM token unavailable',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  Future<SipPushConfig?> _iosVoipConfig() async {
    try {
      final value = await _channel.invokeMapMethod<String, Object?>(
        'getVoipPushToken',
      );
      final token = '${value?['token'] ?? ''}'.trim();
      final provider = '${value?['provider'] ?? ''}'.trim();
      if (token.isEmpty || provider.isEmpty) {
        AppLogger.warning(
          'iOS VoIP push token response missing token/provider',
        );
        return null;
      }
      AppLogger.info(
        'iOS VoIP push token available provider=$provider '
        'param=${_nullableString(value?['param']) ?? "none"} '
        'bundleId=${_nullableString(value?['bundleId']) ?? "none"} '
        'teamId=${_nullableString(value?['teamId']) ?? "none"} '
        'token=${_redactedToken(token)}',
      );
      return SipPushConfig(
        provider: provider,
        token: token,
        param: _nullableString(value?['param']),
        bundleId: _nullableString(value?['bundleId']),
        teamId: _nullableString(value?['teamId']),
      );
    } catch (error, stackTrace) {
      AppLogger.error(
        'iOS VoIP push token unavailable',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }
}

String? _nullableString(Object? value) {
  final text = '${value ?? ''}'.trim();
  return text.isEmpty ? null : text;
}

String _redactedToken(String token) {
  if (token.length <= 12) {
    return '<redacted>';
  }
  return '${token.substring(0, 6)}...${token.substring(token.length - 6)}';
}
