import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/route_names.dart';
import '../../../shared/icons/app_icons.dart';
import '../../../shared/widgets/app_card.dart';
import '../../../shared/widgets/page_content.dart';
import '../../../shared/widgets/section_intro.dart';
import '../domain/device_status.dart';
import '../domain/service_account.dart';
import 'session_controller.dart';

class AccountStatusScreen extends ConsumerStatefulWidget {
  const AccountStatusScreen({super.key});

  @override
  ConsumerState<AccountStatusScreen> createState() =>
      _AccountStatusScreenState();
}

class _AccountStatusScreenState extends ConsumerState<AccountStatusScreen> {
  bool _isResetting = false;

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionControllerProvider).value;
    final service = session?.service;
    final device = session?.device;
    final title = device?.revoked == true
        ? 'Device revoked'
        : service?.serviceStatus.label ?? 'No active service';
    final message = device?.revoked == true
        ? 'This device session has been revoked. Reset the app and activate it with a new provisioning link.'
        : service?.serviceStatus.accountMessage ??
              'Activate this device to continue.';

    return Scaffold(
      body: PageContent(
        maxWidth: 680,
        header: SectionIntro(title: 'Account Status', subtitle: title),
        child: AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(
                AppIcons.warning,
                color: Theme.of(context).colorScheme.error,
                size: 40,
              ),
              const SizedBox(height: 14),
              Text(
                message,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              if (device != null) ...[
                const SizedBox(height: 14),
                Text(
                  'Session: ${device.sessionStatus.label} / Provisioning: ${device.provisioningStatus.label}',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
              const SizedBox(height: 20),
              OutlinedButton.icon(
                onPressed: _isResetting ? null : _resetDevice,
                icon: _isResetting
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(AppIcons.logout),
                label: Text(
                  _isResetting ? 'Resetting device…' : 'Reset device',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _resetDevice() async {
    if (_isResetting) return;
    setState(() => _isResetting = true);
    try {
      await ref.read(sessionControllerProvider.notifier).logout();
      if (mounted) {
        context.go(RoutePaths.provisioning);
      }
    } finally {
      if (mounted) {
        setState(() => _isResetting = false);
      }
    }
  }
}
