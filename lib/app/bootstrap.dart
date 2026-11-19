import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import '../core/logging/app_logger.dart';

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await _initializeFirebaseIfSupported();
}

Future<void> bootstrap(FutureOr<Widget> Function() builder) async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations(const [
    DeviceOrientation.portraitUp,
  ]);
  await _initializeFirebaseIfSupported();
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  }

  FlutterError.onError = (details) {
    // Flutter's debug-only keyboard assertion fires when Caps Lock is toggled on
    // macOS. It is a framework bug, not an app problem, and release builds do
    // not run the assertion.
    if (kDebugMode && _isMacCapsLockAssertion(details.exception)) return;
    FlutterError.presentError(details);
    AppLogger.error(
      'Flutter framework error',
      error: details.exception,
      stackTrace: details.stack,
    );
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    AppLogger.error('Uncaught platform error', error: error, stackTrace: stack);
    return true;
  };

  final app = await builder();
  runApp(ProviderScope(child: app));
}

Future<void> _initializeFirebaseIfSupported() async {
  if (kIsWeb) {
    return;
  }
  final supported =
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS;
  if (!supported || Firebase.apps.isNotEmpty) {
    return;
  }
  try {
    await Firebase.initializeApp();
  } catch (error, stackTrace) {
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      // macOS has no Firebase configuration file yet, so push is simply off.
      AppLogger.info('Firebase is not configured on macOS; push is off');
      return;
    }
    AppLogger.error(
      'Firebase initialization skipped',
      error: error,
      stackTrace: stackTrace,
    );
  }
}

bool _isMacCapsLockAssertion(Object exception) {
  return defaultTargetPlatform == TargetPlatform.macOS &&
      exception.toString().contains(
        'Attempted to send a key down event when no keys are in keysPressed',
      );
}
