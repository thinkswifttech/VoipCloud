import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/app_version_provider.dart';
import '../../../app/router/route_names.dart';
import '../../../app/theme/app_theme.dart';
import '../../../shared/icons/app_icons.dart';
import '../../../shared/widgets/app_brand_icon.dart';
import '../../../shared/widgets/app_card.dart';
import '../../../shared/widgets/page_content.dart';
import '../../../shared/widgets/responsive.dart';
import '../../../shared/widgets/status_pill.dart';
import '../../../voip/platform/android_background_permissions.dart';
import '../../../voip/platform/voip_platform_channel.dart';
import '../../session/presentation/session_controller.dart';
import '../../sip/domain/sip_registration_state.dart';
import 'liblinphone_attribution.dart';
import 'settings_controller.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  bool _isResetting = false;

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionControllerProvider).value;
    final settings = ref.watch(settingsControllerProvider);
    final sip = session?.sipConfig;
    final registration = ref.watch(sipRegistrationStateProvider);

    return PageContent(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final theme = Theme.of(context);
          final expanded = ResponsiveBreakpoints.isExpanded(
            constraints.maxWidth,
          );
          final cards = [
            AppCard(
              title: 'Account',
              subtitle: 'Signed-in user',
              child: AppInfoTile(
                icon: AppIcons.contact,
                title: session?.user.fullName ?? 'No active session',
                subtitle: session?.user.email ?? 'Softphone user',
              ),
            ),
            AppCard(
              title: 'Calling',
              subtitle: 'Call registration and diagnostics',
              child: Column(
                children: [
                  registration.when(
                    data: (state) => AppInfoTile(
                      icon: AppIcons.initialize,
                      title: sip == null
                          ? 'Calling not configured'
                          : _registrationTitle(state.status),
                      subtitle: sip == null
                          ? 'No calling account configured'
                          : state.message ??
                                _registrationDescription(state.status),
                      trailing: StatusPill(
                        label: state.status.name.toUpperCase(),
                        color: _registrationColor(context, state.status),
                      ),
                    ),
                    loading: () => const AppInfoTile(
                      icon: AppIcons.initialize,
                      title: 'Checking registration',
                      subtitle: 'Waiting for calling status',
                    ),
                    error: (_, _) => const AppInfoTile(
                      icon: AppIcons.warning,
                      title: 'Registration unavailable',
                      subtitle: 'Open diagnostics to inspect the SIP service',
                    ),
                  ),
                  const Divider(),
                  AppInfoTile(
                    icon: AppIcons.configure,
                    title: 'Diagnostics',
                    subtitle: 'Registration and setup status',
                    trailing: IconButton(
                      tooltip: 'SIP diagnostics',
                      icon: const Icon(AppIcons.chevronRight),
                      onPressed: () => context.go(RoutePaths.sipDiagnostics),
                    ),
                  ),
                  const Divider(),
                  AppInfoTile(
                    icon: AppIcons.sipLogs,
                    title: 'SIP logs',
                    subtitle: settings.voipDebugLogsEnabled
                        ? 'Logging enabled'
                        : 'Capture registration and call diagnostics',
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Switch.adaptive(
                          value: settings.voipDebugLogsEnabled,
                          onChanged: (value) {
                            ref
                                .read(settingsControllerProvider.notifier)
                                .setVoipDebugLogsEnabled(enabled: value);
                          },
                        ),
                        IconButton(
                          tooltip: 'Open SIP logs',
                          icon: const Icon(AppIcons.chevronRight),
                          onPressed: () => context.go(RoutePaths.sipLogs),
                        ),
                      ],
                    ),
                  ),
                  if (Platform.isAndroid) ...[
                    const Divider(),
                    const _AndroidBackgroundPermissionTile(),
                    const Divider(),
                    const _AndroidFullScreenCallTile(),
                  ],
                ],
              ),
            ),
            AppCard(
              title: 'Appearance',
              subtitle: 'Choose how the app follows your display',
              child: SizedBox(
                width: double.infinity,
                child: SegmentedButton<AppThemeMode>(
                  style: ButtonStyle(
                    backgroundColor: WidgetStateProperty.resolveWith((states) {
                      if (states.contains(WidgetState.selected)) {
                        return AppTheme.swiftRed;
                      }
                      return theme.brightness == Brightness.dark
                          ? theme.colorScheme.surface
                          : Colors.white;
                    }),
                    foregroundColor: WidgetStateProperty.resolveWith((states) {
                      if (states.contains(WidgetState.selected)) {
                        return Colors.white;
                      }
                      return AppTheme.swiftRed;
                    }),
                    side: WidgetStatePropertyAll(
                      BorderSide(
                        color: AppTheme.swiftRed.withValues(alpha: 0.45),
                      ),
                    ),
                    iconColor: WidgetStateProperty.resolveWith((states) {
                      if (states.contains(WidgetState.selected)) {
                        return Colors.white;
                      }
                      return AppTheme.swiftRed;
                    }),
                  ),
                  segments: const [
                    ButtonSegment(
                      value: AppThemeMode.system,
                      icon: Icon(AppIcons.themeSystem),
                      label: Text('System'),
                    ),
                    ButtonSegment(
                      value: AppThemeMode.light,
                      icon: Icon(AppIcons.themeLight),
                      label: Text('Light'),
                    ),
                    ButtonSegment(
                      value: AppThemeMode.dark,
                      icon: Icon(AppIcons.themeDark),
                      label: Text('Dark'),
                    ),
                  ],
                  selected: {settings.themeMode},
                  onSelectionChanged: (selection) {
                    ref
                        .read(settingsControllerProvider.notifier)
                        .setThemeMode(selection.first);
                  },
                ),
              ),
            ),
            const AppCard(
              title: 'About',
              subtitle: 'App information',
              child: _AboutSection(),
            ),
          ];

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (expanded)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: cards[0]),
                    const SizedBox(width: 16),
                    Expanded(child: cards[1]),
                  ],
                )
              else ...[
                cards[0],
                const SizedBox(height: 16),
                cards[1],
              ],
              const SizedBox(height: 16),
              cards[2],
              const SizedBox(height: 16),
              cards[3],
              const SizedBox(height: 16),
              AppCard(
                title: 'Device',
                subtitle: 'Reset this app when you need to activate it again',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        onPressed: _isResetting ? null : _resetApp,
                        icon: _isResetting
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(AppIcons.logout),
                        label: Text(
                          _isResetting ? 'Resetting app…' : 'Reset this app',
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Warning: you will lose everything on this device and '
                      'will have to register again with a QR code or setup link.',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.error,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _resetApp() async {
    if (_isResetting) return;
    setState(() => _isResetting = true);
    try {
      await ref.read(sessionControllerProvider.notifier).revokeDeviceAndReset();
      if (mounted) {
        context.go(RoutePaths.provisioning);
      }
    } finally {
      if (mounted) {
        setState(() => _isResetting = false);
      }
    }
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

  String _registrationTitle(SipRegistrationStatus status) {
    return switch (status) {
      SipRegistrationStatus.registered => 'Registered for calls',
      SipRegistrationStatus.registering => 'Registering for calls',
      SipRegistrationStatus.configuring => 'Configuring calls',
      SipRegistrationStatus.failed => 'Registration failed',
      SipRegistrationStatus.unregistered => 'Not registered for calls',
      SipRegistrationStatus.uninitialized => 'Calling service not initialized',
    };
  }

  String _registrationDescription(SipRegistrationStatus status) {
    return switch (status) {
      SipRegistrationStatus.registered => 'Ready to place and receive calls',
      SipRegistrationStatus.registering => 'Connecting to the calling service',
      SipRegistrationStatus.configuring => 'Calling account is configured',
      SipRegistrationStatus.failed => 'Open diagnostics for details',
      SipRegistrationStatus.unregistered => 'Open diagnostics to register',
      SipRegistrationStatus.uninitialized => 'Open diagnostics to initialize',
    };
  }
}

class _AndroidBackgroundPermissionTile extends StatefulWidget {
  const _AndroidBackgroundPermissionTile();

  @override
  State<_AndroidBackgroundPermissionTile> createState() =>
      _AndroidBackgroundPermissionTileState();
}

class _AndroidBackgroundPermissionTileState
    extends State<_AndroidBackgroundPermissionTile> {
  static const _platformChannel = VoipPlatformChannel();
  bool _loading = true;
  bool _ignored = true;

  @override
  void initState() {
    super.initState();
    unawaited(_refreshStatus());
  }

  Future<void> _refreshStatus() async {
    final ignored = await _platformChannel.isBatteryOptimizationIgnored();
    if (!mounted) {
      return;
    }
    setState(() {
      _ignored = ignored;
      _loading = false;
    });
  }

  Future<void> _openSettings() async {
    await openAndroidBackgroundPermissionSettings(
      platformChannel: _platformChannel,
    );
    await _refreshStatus();
  }

  @override
  Widget build(BuildContext context) {
    final subtitle = _loading
        ? 'Checking battery optimization status'
        : _ignored
        ? 'Background restrictions are disabled for Softphone'
        : 'Allow unrestricted background activity for reliable incoming calls';

    return AppInfoTile(
      icon: AppIcons.warning,
      title: 'Background activity',
      subtitle: subtitle,
      trailing: _loading
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : _ignored
          ? StatusPill(label: 'ALLOWED', color: const Color(0xFF16A34A))
          : TextButton(onPressed: _openSettings, child: const Text('Allow')),
    );
  }
}

class _AndroidFullScreenCallTile extends StatefulWidget {
  const _AndroidFullScreenCallTile();

  @override
  State<_AndroidFullScreenCallTile> createState() =>
      _AndroidFullScreenCallTileState();
}

class _AndroidFullScreenCallTileState extends State<_AndroidFullScreenCallTile>
    with WidgetsBindingObserver {
  static const _platformChannel = VoipPlatformChannel();
  bool _loading = true;
  bool _allowed = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refreshStatus());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshStatus());
    }
  }

  Future<void> _refreshStatus() async {
    final allowed = await _platformChannel.canUseFullScreenIntent();
    if (!mounted) {
      return;
    }
    setState(() {
      _allowed = allowed;
      _loading = false;
    });
  }

  Future<void> _openSettings() async {
    await _platformChannel.requestFullScreenIntentPermission();
  }

  @override
  Widget build(BuildContext context) {
    final subtitle = _loading
        ? 'Checking incoming call display access'
        : _allowed
        ? 'Incoming calls can appear over the lock screen'
        : 'Allow full-screen notifications for locked-screen calls';

    return AppInfoTile(
      icon: AppIcons.callIncoming,
      title: 'Full-screen incoming calls',
      subtitle: subtitle,
      trailing: _loading
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : _allowed
          ? StatusPill(label: 'ALLOWED', color: const Color(0xFF16A34A))
          : TextButton(onPressed: _openSettings, child: const Text('Allow')),
    );
  }
}

class _AboutSection extends ConsumerWidget {
  const _AboutSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final versionLabel = ref
        .watch(appVersionLabelProvider)
        .maybeWhen(data: (label) => label, orElse: () => 'Version');

    return Column(
      children: [
        Row(
          children: [
            const AppBrandIcon(size: 52, circular: false),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'VoipCloud',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    versionLabel,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const Divider(height: 28),
        const LiblinphoneAttributionTile(),
      ],
    );
  }
}
