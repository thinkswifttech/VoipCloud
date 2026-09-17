import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../features/calls/presentation/call_session_providers.dart';
import '../../features/calls/presentation/return_to_call_bar.dart';
import '../../features/call_history/presentation/call_history_providers.dart';
import '../../features/session/presentation/session_controller.dart';
import '../../features/messages/domain/messaging_platform.dart';
import '../../features/messages/presentation/messages_providers.dart';
import '../../shared/icons/app_icons.dart';
import '../../shared/platform/desktop_platform.dart';
import '../../shared/widgets/help_support_sheet.dart';
import '../../shared/widgets/desktop_update_badge.dart';
import '../../shared/widgets/responsive.dart';
import '../../voip/platform/voip_platform_channel.dart';
import 'app_navigation.dart';
import 'route_names.dart';

typedef AppBadgeCounts = ({int missedCalls, int unreadMessages});

final appBadgeCountsProvider = Provider<AppBadgeCounts>((ref) {
  final rawMissedCalls = ref.watch(missedCallCountProvider).value ?? 0;
  final missedCalls = rawMissedCalls < 0 ? 0 : rawMissedCalls;
  if (!isCarrierMessagingSupported()) {
    return (missedCalls: missedCalls, unreadMessages: 0);
  }

  // Keep messaging discovery alive even when provisioning did not embed the
  // carrier assignment. Discovery can populate carrierMessaging and make the
  // SMS destination visible; gating this watch on the current entitlement
  // creates a deadlock where discovery can never start.
  final messaging = ref.watch(messagesControllerProvider);
  final appSession = ref.watch(sessionControllerProvider).value;
  if (!isCarrierMessagingEnabled(appSession?.carrierMessaging)) {
    return (missedCalls: missedCalls, unreadMessages: 0);
  }
  final unreadMessages = messaging.unreadByRemoteNumber.values.fold<int>(
    0,
    (total, count) => total + (count < 0 ? 0 : count),
  );
  return (missedCalls: missedCalls, unreadMessages: unreadMessages);
});

class HomeShell extends ConsumerWidget {
  const HomeShell({required this.child, required this.location, super.key});

  final Widget child;
  final String location;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appSession = ref.watch(sessionControllerProvider).value;
    final showDirectory = appSession?.directoryAccess != null;
    final showCarrierMessaging = isCarrierMessagingEnabled(
      appSession?.carrierMessaging,
    );
    final navigationPaths = appNavigationPaths(
      showDirectory: showDirectory,
      showCarrierMessaging: showCarrierMessaging,
    );
    final index = appNavigationIndexForLocation(location, navigationPaths);
    // This provider also keeps messaging discovery, push registration, unread
    // state, and realtime delivery alive outside the SMS route.
    final badgeCounts = ref.watch(appBadgeCountsProvider);
    final unreadMessages = badgeCounts.unreadMessages;
    final missedCalls = badgeCounts.missedCalls;
    final isDialer =
        location.startsWith(RoutePaths.dialer) ||
        location.startsWith(RoutePaths.home);
    final isSettings = location.startsWith(RoutePaths.settings);
    final isDirectory = location.startsWith(RoutePaths.directory);
    final desktopPlatform = isSupportedDesktopPlatform();
    final transferMode = ref.watch(callTransferModeProvider);
    final showTransferChrome = transferMode && isDirectory;
    final liveCall = ref.watch(activeCallProvider).value;
    final showReturnToCall =
        isInCallUiCall(liveCall) && !isDialer && !isSettings;
    final title = showTransferChrome
        ? 'Transfer call'
        : _titleForLocation(location);

    return _NativeAppBadgeSync(
      counts: badgeCounts,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final showRail = constraints.maxWidth >= 780;
          final extendRail = ResponsiveBreakpoints.isExpanded(
            constraints.maxWidth,
          );

          void selectDestination(int next) {
            if (next < 0 || next >= navigationPaths.length) return;
            if (transferMode && navigationPaths[next] != RoutePaths.directory) {
              ref.read(callTransferModeProvider.notifier).clear();
            }
            context.go(navigationPaths[next]);
          }

          final scaffold = Scaffold(
            appBar: isDialer && !desktopPlatform
                ? null
                : AppBar(
                    leading: showTransferChrome
                        ? IconButton(
                            tooltip: 'Cancel transfer',
                            onPressed: () {
                              // Cancel transfer only — never end the active call.
                              ref
                                  .read(callTransferModeProvider.notifier)
                                  .clear();
                              context.go(RoutePaths.dialer);
                            },
                            icon: const Icon(AppIcons.close),
                          )
                        : isSettings
                        ? IconButton(
                            tooltip: 'Back',
                            onPressed: () {
                              if (context.canPop()) {
                                context.pop();
                              } else {
                                context.go(RoutePaths.dialer);
                              }
                            },
                            icon: const Icon(AppIcons.back),
                          )
                        : null,
                    title: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      child: Text(title, key: ValueKey(title)),
                    ),
                    actions: isSettings || showTransferChrome
                        ? null
                        : [
                            IconButton(
                              tooltip: 'Help & support',
                              onPressed: () => showHelpSupportSheet(context),
                              icon: const Icon(AppIcons.help),
                            ),
                            IconButton.outlined(
                              tooltip: 'Settings',
                              onPressed: () =>
                                  context.push(RoutePaths.settings),
                              icon: const DesktopUpdateBadge(
                                child: Icon(AppIcons.navSettings),
                              ),
                            ),
                            const SizedBox(width: 8),
                          ],
                  ),
            body: Column(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      if (showRail && !isSettings) ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.surface,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: Theme.of(context).colorScheme.outline,
                              ),
                            ),
                            child: _AppNavigationRail(
                              selectedIndex: index,
                              extended: extendRail,
                              showDirectory: showDirectory,
                              showCarrierMessaging: showCarrierMessaging,
                              unreadMessages: unreadMessages,
                              missedCalls: missedCalls,
                              onDestinationSelected: selectDestination,
                            ),
                          ),
                        ),
                      ],
                      Expanded(
                        child: ColoredBox(
                          color: Theme.of(context).colorScheme.surface,
                          child: child,
                        ),
                      ),
                    ],
                  ),
                ),
                if (showReturnToCall) const ReturnToCallBar(),
              ],
            ),
            bottomNavigationBar: showRail || isSettings
                ? null
                : NavigationBar(
                    selectedIndex: index,
                    onDestinationSelected: selectDestination,
                    destinations: [
                      const NavigationDestination(
                        icon: Icon(AppIcons.navDialer),
                        selectedIcon: Icon(AppIcons.navDialer),
                        label: 'Dial',
                      ),
                      if (showDirectory)
                        const NavigationDestination(
                          icon: Icon(AppIcons.navDirectory),
                          selectedIcon: Icon(AppIcons.navDirectory),
                          label: 'Directory',
                        ),
                      NavigationDestination(
                        icon: _HistoryNavIcon(unread: missedCalls),
                        selectedIcon: _HistoryNavIcon(unread: missedCalls),
                        label: 'History',
                      ),
                      const NavigationDestination(
                        icon: Icon(AppIcons.navContacts),
                        selectedIcon: Icon(AppIcons.navContacts),
                        label: 'Contacts',
                      ),
                      if (showCarrierMessaging)
                        NavigationDestination(
                          icon: _MessageNavIcon(unread: unreadMessages),
                          selectedIcon: _MessageNavIcon(unread: unreadMessages),
                          label: 'SMS',
                        ),
                    ],
                  ),
          );

          if (!desktopPlatform) return scaffold;
          final bindings = <ShortcutActivator, VoidCallback>{
            const SingleActivator(
              LogicalKeyboardKey.comma,
              control: true,
            ): () =>
                context.push(RoutePaths.settings),
            const SingleActivator(LogicalKeyboardKey.comma, meta: true): () =>
                context.push(RoutePaths.settings),
          };
          final digitKeys = <LogicalKeyboardKey>[
            LogicalKeyboardKey.digit1,
            LogicalKeyboardKey.digit2,
            LogicalKeyboardKey.digit3,
            LogicalKeyboardKey.digit4,
            LogicalKeyboardKey.digit5,
          ];
          for (
            var shortcutIndex = 0;
            shortcutIndex < navigationPaths.length &&
                shortcutIndex < digitKeys.length;
            shortcutIndex++
          ) {
            final destinationIndex = shortcutIndex;
            bindings[SingleActivator(
              digitKeys[shortcutIndex],
              control: true,
            )] = () =>
                selectDestination(destinationIndex);
            bindings[SingleActivator(
              digitKeys[shortcutIndex],
              meta: true,
            )] = () =>
                selectDestination(destinationIndex);
          }
          return CallbackShortcuts(
            bindings: bindings,
            child: Focus(autofocus: true, child: scaffold),
          );
        },
      ),
    );
  }

  String _titleForLocation(String location) {
    if (location.startsWith(RoutePaths.directory)) return 'Directory';
    if (location.startsWith(RoutePaths.callHistory)) return 'Call history';
    if (location.startsWith(RoutePaths.contacts)) return 'Contacts';
    if (location.startsWith(RoutePaths.messages)) return 'Messages';
    if (location.startsWith(RoutePaths.settings)) return 'Settings';
    return 'Dial';
  }
}

const _badgePlatformChannel = VoipPlatformChannel();

class _NativeAppBadgeSync extends StatefulWidget {
  const _NativeAppBadgeSync({required this.counts, required this.child});

  final AppBadgeCounts counts;
  final Widget child;

  @override
  State<_NativeAppBadgeSync> createState() => _NativeAppBadgeSyncState();
}

class _NativeAppBadgeSyncState extends State<_NativeAppBadgeSync> {
  @override
  void initState() {
    super.initState();
    _scheduleSync();
  }

  @override
  void didUpdateWidget(covariant _NativeAppBadgeSync oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.counts != widget.counts) _scheduleSync();
  }

  void _scheduleSync() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_setNativeAppBadge(widget.counts));
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

Future<void> _setNativeAppBadge(AppBadgeCounts counts) async {
  final total = counts.missedCalls + counts.unreadMessages;
  try {
    await _badgePlatformChannel.setAppBadgeCount(
      total,
      missedCalls: counts.missedCalls,
      unreadMessages: counts.unreadMessages,
    );
  } on MissingPluginException {
    // Tests and older native shells may not expose app badge support.
  } on PlatformException {
    // The in-app History and Messages badges remain authoritative if the OS
    // declines launcher badge updates.
  }
}

class _AppNavigationRail extends StatelessWidget {
  const _AppNavigationRail({
    required this.selectedIndex,
    required this.extended,
    required this.onDestinationSelected,
    required this.showDirectory,
    required this.showCarrierMessaging,
    required this.unreadMessages,
    required this.missedCalls,
  });

  final int selectedIndex;
  final bool extended;
  final ValueChanged<int> onDestinationSelected;
  final bool showDirectory;
  final bool showCarrierMessaging;
  final int unreadMessages;
  final int missedCalls;

  @override
  Widget build(BuildContext context) {
    return NavigationRail(
      selectedIndex: selectedIndex,
      extended: extended,
      minWidth: 84,
      minExtendedWidth: 220,
      groupAlignment: -0.78,
      // An extended rail renders destination labels itself. Flutter asserts
      // if `all` is also supplied while the rail is extended.
      labelType: extended
          ? NavigationRailLabelType.none
          : NavigationRailLabelType.all,
      onDestinationSelected: onDestinationSelected,
      destinations: [
        const NavigationRailDestination(
          icon: Icon(AppIcons.navDialer),
          selectedIcon: Icon(AppIcons.navDialer),
          label: Text('Dial'),
        ),
        if (showDirectory)
          const NavigationRailDestination(
            icon: Icon(AppIcons.navDirectory),
            selectedIcon: Icon(AppIcons.navDirectory),
            label: Text('Directory'),
          ),
        NavigationRailDestination(
          icon: _HistoryNavIcon(unread: missedCalls),
          selectedIcon: _HistoryNavIcon(unread: missedCalls),
          label: const Text('History'),
        ),
        const NavigationRailDestination(
          icon: Icon(AppIcons.navContacts),
          selectedIcon: Icon(AppIcons.navContacts),
          label: Text('Contacts'),
        ),
        if (showCarrierMessaging)
          NavigationRailDestination(
            icon: _MessageNavIcon(unread: unreadMessages),
            selectedIcon: _MessageNavIcon(unread: unreadMessages),
            label: const Text('SMS'),
          ),
      ],
    );
  }
}

class _MessageNavIcon extends StatelessWidget {
  const _MessageNavIcon({required this.unread});

  final int unread;

  @override
  Widget build(BuildContext context) {
    final label = unread > 99 ? '99+' : '$unread';
    return Badge(
      isLabelVisible: unread > 0,
      label: Text(label),
      child: const Icon(AppIcons.messages),
    );
  }
}

class _HistoryNavIcon extends StatelessWidget {
  const _HistoryNavIcon({required this.unread});

  final int unread;

  @override
  Widget build(BuildContext context) {
    final label = unread > 99 ? '99+' : '$unread';
    return Badge(
      isLabelVisible: unread > 0,
      label: Text(label),
      child: const Icon(AppIcons.navHistory),
    );
  }
}
