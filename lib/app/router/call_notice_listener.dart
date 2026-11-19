import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/calls/presentation/call_notice_provider.dart';

/// Shows a pending call notice when the app comes back to the foreground.
class CallNoticeListener extends ConsumerStatefulWidget {
  const CallNoticeListener({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<CallNoticeListener> createState() => _CallNoticeListenerState();
}

class _CallNoticeListenerState extends ConsumerState<CallNoticeListener>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _showPending();
  }

  void _showPending() {
    final notice = ref.read(pendingCallNoticeProvider);
    if (notice == null || !mounted) return;
    ref.read(pendingCallNoticeProvider.notifier).clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      messenger?.showSnackBar(
        SnackBar(
          content: Text('Call disconnected. $notice'),
          duration: const Duration(seconds: 20),
          action: SnackBarAction(label: 'OK', onPressed: () {}),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
