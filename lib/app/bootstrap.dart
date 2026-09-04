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
    AppLogger.error(
      'Firebase initialization skipped',
      error: error,
      stackTrace: stackTrace,
    );
  }
}
