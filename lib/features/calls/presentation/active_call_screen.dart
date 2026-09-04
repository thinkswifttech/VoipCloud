import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/route_names.dart';
import '../../../shared/widgets/page_content.dart';
import '../../session/presentation/session_controller.dart';
import 'in_call_panel.dart';

/// Fallback deep-link route; connected calls live on Dial inside the shell.
class ActiveCallScreen extends ConsumerWidget {
  const ActiveCallScreen({required this.callId, super.key});

  final String callId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final call = ref.watch(activeCallProvider).value;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!context.mounted) return;
      context.go(RoutePaths.dialer);
    });

    if (call == null || call.id != callId) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      body: SafeArea(
        child: PageContent(
          maxWidth: 460,
          scrollable: false,
          padding: const EdgeInsets.fromLTRB(24, 18, 24, 24),
          child: InCallPanel(call: call, enableProximity: false),
        ),
      ),
    );
  }
}
