import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/route_names.dart';
import '../../../app/theme/app_theme.dart';
import '../../../shared/icons/app_icons.dart';
import '../../contacts/presentation/contacts_providers.dart';
import '../../directory/presentation/directory_providers.dart';
import '../../session/presentation/session_controller.dart';
import '../domain/voip_call.dart';
import 'call_session_providers.dart';
import 'caller_identity.dart';

/// Thin bar above bottom nav / under content when browsing while on a call.
class ReturnToCallBar extends ConsumerWidget {
  const ReturnToCallBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final call = ref.watch(activeCallProvider).value;
    if (!isInCallUiCall(call)) {
      return const SizedBox.shrink();
    }
    final contacts = ref.watch(contactsProvider).value ?? const [];
    final directory = ref.watch(directoryProvider).value ?? const [];
    final identity = resolveCallerIdentity(
      call: call,
      contacts: contacts,
      directory: directory,
    );
    return _ReturnToCallBarBody(
      call: call!,
      label: identity.label,
      onReturn: () {
        ref.read(callTransferModeProvider.notifier).clear();
        context.go(RoutePaths.dialer);
      },
    );
  }
}

class _ReturnToCallBarBody extends StatefulWidget {
  const _ReturnToCallBarBody({
    required this.call,
    required this.label,
    required this.onReturn,
  });

  final VoipCall call;
  final String label;
  final VoidCallback onReturn;

  @override
  State<_ReturnToCallBarBody> createState() => _ReturnToCallBarBodyState();
}

class _ReturnToCallBarBodyState extends State<_ReturnToCallBarBody> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final call = widget.call;
    final label = widget.label;
    final elapsed = DateTime.now().difference(call.startedAt);
    final duration = _formatDuration(elapsed);

    return Material(
      color: theme.colorScheme.primary,
      child: InkWell(
        onTap: widget.onReturn,
        child: SafeArea(
          top: false,
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                Icon(
                  AppIcons.call,
                  size: AppIconSize.sm,
                  color: theme.colorScheme.onPrimary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelLarge?.copyWith(
                      fontFamily: AppTheme.bodyFontFamily,
                      color: theme.colorScheme.onPrimary,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0,
                    ),
                  ),
                ),
                Text(
                  duration,
                  style: AppTheme.numberStyle(
                    theme.textTheme.labelLarge?.copyWith(
                      color: theme.colorScheme.onPrimary,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  AppIcons.chevronRight,
                  size: AppIconSize.sm,
                  color: theme.colorScheme.onPrimary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _formatDuration(Duration value) {
    final totalSeconds = value.inSeconds.clamp(0, 99 * 3600);
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }
}
