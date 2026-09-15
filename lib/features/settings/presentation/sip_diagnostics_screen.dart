import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/route_names.dart';
import '../../../core/app_version_provider.dart';
import '../../../shared/icons/app_icons.dart';
import '../../../shared/widgets/app_card.dart';
import '../../../shared/widgets/page_content.dart';
import '../../../shared/widgets/status_pill.dart';
import '../../session/domain/device_status.dart';
import '../../session/presentation/session_controller.dart';
import '../../sip/domain/sip_config.dart';
import '../../sip/domain/sip_registration_state.dart';

class SipDiagnosticsScreen extends ConsumerWidget {
  const SipDiagnosticsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionControllerProvider).value;
    final runtimeSip = ref.watch(sipServiceProvider).currentConfig;
    final sip = runtimeSip ?? session?.sipConfig;
    final device = session?.device;
    final registration = ref.watch(sipRegistrationStateProvider);
    final appVersion = ref.watch(appVersionInfoProvider);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Back',
          onPressed: () {
            if (context.canPop()) {
              context.pop();
            } else {
              context.go(RoutePaths.settings);
            }
          },
          icon: const Icon(AppIcons.back),
        ),
        title: const Text('SIP diagnostics'),
      ),
      body: PageContent(
        child: Column(
          children: [
            AppCard(
              title: 'Registration',
              subtitle: 'Current calling status',
              child: registration.when(
                data: (state) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          StatusPill(
                            label: state.status.name.toUpperCase(),
                            color: _statusColor(context, state.status),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _statusDescription(state.status),
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ),
                        ],
                      ),
                      if (state.message != null) ...[
                        const SizedBox(height: 10),
                        Text(state.message!),
                      ],
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          OutlinedButton.icon(
                            onPressed: sip == null
                                ? null
                                : () => ref
                                      .read(sipServiceProvider)
                                      .refreshConfig(sip),
                            icon: const Icon(AppIcons.configure),
                            label: const Text('Refresh config'),
                          ),
                          FilledButton.icon(
                            onPressed: sip == null
                                ? null
                                : () => ref.read(sipServiceProvider).register(),
                            icon: const Icon(AppIcons.login),
                            label: const Text('Register'),
                          ),
                          OutlinedButton.icon(
                            onPressed: () =>
                                ref.read(sipServiceProvider).unregister(),
                            icon: const Icon(AppIcons.logout),
                            label: const Text('Unregister'),
                          ),
                        ],
                      ),
                    ],
                  );
                },
                loading: () => const Text('Waiting for registration state...'),
                error: (_, _) => const Text('Registration state unavailable.'),
              ),
            ),
            const SizedBox(height: 16),
            AppCard(
              title: 'Calling setup',
              subtitle: 'Account details used for calls',
              child: sip == null
                  ? const Text(
                      'No calling account is configured on this device.',
                    )
                  : _DiagnosticList(
                      items: [
                        _DiagnosticEntry('Extension', sip.extension),
                        _DiagnosticEntry('Account domain', sip.domain),
                        _DiagnosticEntry(
                          'Transport',
                          '${sip.transportLabel} ${sip.port}',
                        ),
                      ],
                    ),
            ),
            const SizedBox(height: 16),
            AppCard(
              title: 'Device',
              subtitle: 'Provisioning state for this phone',
              child: _DiagnosticList(
                items: [
                  _DiagnosticEntry(
                    'Device session',
                    device?.sessionStatus.label ?? 'Unknown',
                  ),
                  _DiagnosticEntry(
                    'Setup',
                    device?.provisioningStatus.label ?? 'Unknown',
                  ),
                  _DiagnosticEntry(
                    'SIP identity',
                    device?.sipIdentity ?? sip?.sipIdentity ?? 'Not set',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            AppCard(
              title: 'Application',
              subtitle: 'Build details for administrator support',
              child: appVersion.when(
                data: (info) => _DiagnosticList(
                  items: [
                    _DiagnosticEntry('Version', info.version),
                    _DiagnosticEntry('Build number', info.buildNumber),
                  ],
                ),
                loading: () => const Text('Loading application details...'),
                error: (_, _) => const Text(
                  'Application build details are unavailable.',
                ),
              ),
            ),
            if (sip != null) ...[
              const SizedBox(height: 16),
              AppCard(
                title: 'Advanced details',
                subtitle: 'For administrator support',
                child: _AdvancedSipDetails(sip: sip),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Color _statusColor(BuildContext context, SipRegistrationStatus status) {
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

  String _statusDescription(SipRegistrationStatus status) {
    return switch (status) {
      SipRegistrationStatus.registered => 'Ready for calls',
      SipRegistrationStatus.registering => 'Registration in progress',
      SipRegistrationStatus.configuring => 'Account configured locally',
      SipRegistrationStatus.failed => 'Registration failed',
      SipRegistrationStatus.unregistered => 'Not currently registered',
      SipRegistrationStatus.uninitialized =>
        'Native SIP service not initialized',
    };
  }
}

String _authMode(SipConfig sip) {
  final hasPassword = sip.password.trim().isNotEmpty;
  final hasHa1 = sip.ha1?.trim().isNotEmpty == true;
  if (hasPassword && hasHa1) {
    return 'Password and HA1 stored';
  }
  if (hasPassword) {
    return 'Password stored securely';
  }
  if (hasHa1) {
    return 'HA1 only';
  }
  return 'Missing credentials';
}

class _AdvancedSipDetails extends StatelessWidget {
  const _AdvancedSipDetails({required this.sip});

  final SipConfig sip;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.zero,
        leading: const Icon(AppIcons.configure),
        title: const Text('Show SIP and push details'),
        subtitle: const Text('Use when support asks for technical details'),
        children: [
          const SizedBox(height: 8),
          _DiagnosticList(
            items: [
              _DiagnosticEntry('Auth realm', sip.realm ?? sip.domain),
              _DiagnosticEntry('Auth username', sip.authUsername),
              _DiagnosticEntry(
                'Auth domain',
                sip.authDomain ?? sip.realm ?? sip.domain,
              ),
              _DiagnosticEntry('PBX registrar', sip.registrar),
              _DiagnosticEntry(
                'Linphone server',
                sip.outboundProxy.trim().isEmpty
                    ? sip.registrar
                    : sip.outboundProxy,
              ),
              _DiagnosticEntry(
                'Routing mode',
                sip.outboundProxy.trim().isEmpty
                    ? 'Direct to PBX registrar'
                    : 'PBX registrar via Flexisip route',
              ),
              if (sip.outboundProxy.trim().isNotEmpty)
                _DiagnosticEntry('Flexisip route', sip.outboundProxy),
              _DiagnosticEntry('Authentication', _authMode(sip)),
              _DiagnosticEntry(
                'Digest algorithm',
                sip.algorithm ?? 'Server default',
              ),
              _DiagnosticEntry(
                'Push provider',
                sip.pushConfig?.provider ?? 'Not configured',
              ),
              _DiagnosticEntry(
                'Push app id / param',
                sip.pushConfig?.param ?? 'Not configured',
              ),
              _DiagnosticEntry(
                'Push bundle id',
                sip.pushConfig?.bundleId ?? 'Not configured',
              ),
              _DiagnosticEntry(
                'Push token',
                sip.pushConfig?.token.isNotEmpty == true
                    ? 'Available'
                    : 'Not available',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DiagnosticList extends StatelessWidget {
  const _DiagnosticList({required this.items});

  final List<_DiagnosticEntry> items;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final (index, item) in items.indexed) ...[
          _DiagnosticItem(label: item.label, value: item.value),
          if (index != items.length - 1) const Divider(),
        ],
      ],
    );
  }
}

class _DiagnosticEntry {
  const _DiagnosticEntry(this.label, this.value);

  final String label;
  final String value;
}

class _DiagnosticItem extends StatelessWidget {
  const _DiagnosticItem({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final displayValue = value.trim().isEmpty ? 'Not set' : value;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 2,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            flex: 3,
            child: Text(
              displayValue,
              textAlign: TextAlign.end,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
