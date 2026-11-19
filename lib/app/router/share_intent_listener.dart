import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/messages/presentation/shared_content.dart';
import '../../features/session/presentation/session_controller.dart';
import 'route_names.dart';

/// Opens the "send to" screen when another app shares a link or photos with
/// VoipCloud (Android share sheet, iOS share extension).
class ShareIntentListener extends ConsumerStatefulWidget {
  const ShareIntentListener({
    required this.router,
    required this.child,
    super.key,
  });

  final GoRouter router;
  final Widget child;

  @override
  ConsumerState<ShareIntentListener> createState() =>
      _ShareIntentListenerState();
}

class _ShareIntentListenerState extends ConsumerState<ShareIntentListener> {
  static const _channel = MethodChannel('voipcloud/share_intents');

  SharedContent? _pending;
  final Set<String> _handledIds = <String>{};

  bool get _isSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);

  @override
  void initState() {
    super.initState();
    if (!_isSupported) return;
    widget.router.routeInformationProvider.addListener(_routeWhenReady);
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'shareReceived' && call.arguments is Map) {
        _receive(call.arguments as Map);
      }
      return null;
    });
    unawaited(_consumePending());
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

  Future<void> _consumePending() async {
    try {
      _receive(
        await _channel.invokeMapMethod<String, dynamic>('consumePendingShare'),
      );
    } on MissingPluginException {
      // Native support is absent in tests and older installed builds.
    }
  }

  void _receive(Map<dynamic, dynamic>? payload) {
    final content = SharedContent.fromPayload(payload);
    if (content == null) return;
    _pending = content;
    _routeWhenReady();
  }

  void _routeWhenReady() {
    if (!mounted) return;
    final content = _pending;
    if (content == null) return;
    final path = widget.router.routeInformationProvider.value.uri.path;
    final session = ref.read(sessionControllerProvider).value;
    if (session == null ||
        path == RoutePaths.splash ||
        path == RoutePaths.termsAgreement ||
        path.startsWith('/calls/')) {
      return;
    }
    _pending = null;
    if (!_handledIds.add(content.id)) return;
    ref.read(sharedContentProvider.notifier).set(content);
    if (path != RoutePaths.shareToMessage) {
      unawaited(widget.router.push(RoutePaths.shareToMessage));
    }
  }
}
