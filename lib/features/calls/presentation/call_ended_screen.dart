import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/route_names.dart';
import '../../../app/theme/app_theme.dart';
import '../../../shared/icons/app_icons.dart';

class CallEndedScreen extends StatefulWidget {
  const CallEndedScreen({required this.statusLabel, this.caller, super.key});

  final String statusLabel;
  final String? caller;

  @override
  State<CallEndedScreen> createState() => _CallEndedScreenState();
}

class _CallEndedScreenState extends State<CallEndedScreen> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(milliseconds: 1300), _goToDialer);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final callerText = widget.caller;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircleAvatar(
                  radius: 40,
                  backgroundColor: theme.colorScheme.errorContainer,
                  child: Icon(
                    AppIcons.callEnd,
                    color: theme.colorScheme.onErrorContainer,
                    size: 34,
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  widget.statusLabel,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0,
                  ),
                ),
                if (callerText != null && callerText.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    callerText,
                    textAlign: TextAlign.center,
                    style: AppTheme.numberStyle(
                      theme.textTheme.bodyLarge,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _goToDialer() {
    if (!mounted) return;
    context.go(RoutePaths.dialer);
  }
}
