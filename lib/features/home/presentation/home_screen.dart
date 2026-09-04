import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/route_names.dart';
import '../../../shared/icons/app_icons.dart';
import '../../../shared/widgets/app_card.dart';
import '../../../shared/widgets/page_content.dart';
import '../../../shared/widgets/section_intro.dart';
import '../../../shared/widgets/status_pill.dart';
import '../../session/domain/device_status.dart';
import '../../session/domain/service_account.dart';
import '../../session/presentation/session_controller.dart';
import '../../messages/domain/messaging_platform.dart';
import '../../sip/domain/sip_registration_state.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessionAsync = ref.watch(sessionControllerProvider);
    final registration = ref.watch(sipRegistrationStateProvider);

    return sessionAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => PageContent(
        child: AppCard(child: Text('Unable to load session: $error')),
      ),
      data: (session) {
        if (session == null) {
          return const _MissingSession();
        }
        final sip = session.sipConfig;

        return PageContent(
          header: SectionIntro(
            title: 'Softphone Home',
            subtitle: session.user.fullName,
            trailing: StatusPill(
              label: session.service.serviceStatus.label,
              color: _serviceColor(context, session.service.serviceStatus),
            ),
          ),
          child: Column(
            children: [
              AppCard(
                title: 'Service',
                child: Column(
                  children: [
                    AppInfoTile(
                      icon: AppIcons.contact,
                      title: session.user.fullName,
                      subtitle: session.user.email ?? 'No email on profile',
                    ),
                    const Divider(),
                    AppInfoTile(
                      icon: AppIcons.sipDiagnostics,
                      title: sip?.extension ?? 'No active extension',
                      subtitle: sip == null
                          ? 'SIP is disabled for this service state'
                          : '${sip.sipIdentity} via ${sip.transportLabel}',
                    ),
                    const Divider(),
                    AppInfoTile(
                      icon: AppIcons.configure,
                      title: session.device.sessionStatus.label,
                      subtitle: session.device.provisioningStatus.label,
                    ),
                    const Divider(),
                    registration.when(
                      data: (state) => AppInfoTile(
                        icon: AppIcons.initialize,
                        title: state.status.name,
                        subtitle: state.message ?? 'SIP service idle',
                        trailing: StatusPill(
                          label: state.status.name.toUpperCase(),
                          color: _registrationColor(context, state.status),
                        ),
                      ),
                      loading: () => const LinearProgressIndicator(),
                      error: (_, _) => AppInfoTile(
                        icon: AppIcons.warning,
                        title: 'Unavailable',
                        subtitle: 'SIP registration state is unavailable',
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              GridView.count(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisCount: MediaQuery.sizeOf(context).width < 640 ? 2 : 3,
                childAspectRatio: 1.25,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
                children: [
                  _HomeAction(
                    icon: AppIcons.navDialer,
                    label: 'Dial',
                    onTap: () => context.go(RoutePaths.dialer),
                  ),
                  if (session.directoryAccess != null)
                    _HomeAction(
                      icon: AppIcons.navDirectory,
                      label: 'Directory',
                      onTap: () => context.go(RoutePaths.directory),
                    ),
                  _HomeAction(
                    icon: AppIcons.navContacts,
                    label: 'Contacts',
                    onTap: () => context.go(RoutePaths.contacts),
                  ),
                  _HomeAction(
                    icon: AppIcons.navHistory,
                    label: 'Call history',
                    onTap: () => context.go(RoutePaths.callHistory),
                  ),
                  if (isCarrierMessagingEnabled(session.carrierMessaging))
                    _HomeAction(
                      icon: AppIcons.messages,
                      label: 'SMS',
                      onTap: () => context.go(RoutePaths.messages),
                    ),
                  _HomeAction(
                    icon: AppIcons.navSettings,
                    label: 'Settings',
                    onTap: () => context.go(RoutePaths.settings),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Color _serviceColor(BuildContext context, ServiceStatus status) {
    return switch (status) {
      ServiceStatus.active => const Color(0xFF16A34A),
      ServiceStatus.pending => const Color(0xFFD97706),
      ServiceStatus.suspended ||
      ServiceStatus.terminated ||
      ServiceStatus.cancelled => Theme.of(context).colorScheme.error,
      ServiceStatus.unknown => Theme.of(context).colorScheme.primary,
    };
  }

  Color _registrationColor(BuildContext context, SipRegistrationStatus status) {
    return switch (status) {
      SipRegistrationStatus.registered => const Color(0xFF16A34A),
      SipRegistrationStatus.failed => Theme.of(context).colorScheme.error,
      SipRegistrationStatus.registering ||
      SipRegistrationStatus.configuring => const Color(0xFFD97706),
      SipRegistrationStatus.uninitialized ||
      SipRegistrationStatus.unregistered => Theme.of(
        context,
      ).colorScheme.primary,
    };
  }
}

class _HomeAction extends StatelessWidget {
  const _HomeAction({required this.icon, required this.label, this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon),
          const SizedBox(height: 8),
          Text(label, textAlign: TextAlign.center),
        ],
      ),
    );
  }
}

class _MissingSession extends StatelessWidget {
  const _MissingSession();

  @override
  Widget build(BuildContext context) {
    return PageContent(
      child: AppCard(
        child: FilledButton(
          onPressed: () => context.go(RoutePaths.provisioning),
          child: const Text('Activate device'),
        ),
      ),
    );
  }
}
