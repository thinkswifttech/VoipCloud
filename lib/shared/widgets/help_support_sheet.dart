import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../features/messages/domain/messaging_platform.dart';
import '../../features/session/presentation/session_controller.dart';
import '../icons/app_icons.dart';

Future<void> showHelpSupportSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    builder: (_) => const HelpSupportSheet(),
  );
}

class HelpSupportSheet extends ConsumerWidget {
  const HelpSupportSheet({super.key});

  static const _ticketUrl =
      'https://whmcs.thinkswift.com/submitticket.php?deptid=1&step=2';
  static const _guidesUrl = 'https://guides.thinkswift.com/';
  static const _supportEmail = 'support@thinkswift.com';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final canMessage = isCarrierMessagingEnabled(
      ref.watch(sessionControllerProvider).value?.carrierMessaging,
    );

    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        4,
        20,
        20 + MediaQuery.paddingOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Help & support', style: theme.textTheme.titleLarge),
            const SizedBox(height: 6),
            Text(
              'Quick guides and ways to get in touch with ThinkSwift.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 20),
            Text('Guides', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            const _HelpGuideTile(
              icon: AppIcons.call,
              title: 'Making calls',
              body:
                  'Open Dial, enter a number or extension, then tap Call. '
                  'Use Directory or Contacts to place a call without typing.',
            ),
            const _HelpGuideTile(
              icon: AppIcons.cloud,
              title: 'Registration status',
              body:
                  'Tap your extension at the top of Dial to see account detail. '
                  'Green means registered and ready to send or receive calls.',
            ),
            const _HelpGuideTile(
              icon: AppIcons.bellOff,
              title: 'Do not disturb',
              body:
                  'Choose This device to silence only this installation, or '
                  'All devices to apply PBX DND to the whole extension. '
                  'Unanswered calls appear as missed.',
            ),
            if (canMessage)
              const _HelpGuideTile(
                icon: AppIcons.messages,
                title: 'Messages',
                body:
                    'Use the SMS tab for carrier text messages when messaging '
                    'is enabled for your assigned number.',
              ),
            _HelpContactTile(
              icon: AppIcons.externalLink,
              title: 'Swift Guides',
              subtitle: 'guides.thinkswift.com',
              onTap: () => _openExternal(_guidesUrl),
            ),
            const SizedBox(height: 18),
            Text('Contact', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            _HelpContactTile(
              icon: AppIcons.lifeBuoy,
              title: 'Submit a support ticket',
              subtitle: 'Open the ThinkSwift help desk',
              onTap: () => _openExternal(_ticketUrl),
            ),
            _HelpContactTile(
              icon: AppIcons.email,
              title: 'Email support',
              subtitle: _supportEmail,
              onTap: () => _openExternal('mailto:$_supportEmail'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _openExternal(String url) async {
    final uri = Uri.parse(url);
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}

class _HelpGuideTile extends StatelessWidget {
  const _HelpGuideTile({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: theme.colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  body,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HelpContactTile extends StatelessWidget {
  const _HelpContactTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: theme.colorScheme.primary),
      title: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w700,
        ),
      ),
      subtitle: Text(subtitle),
      trailing: Icon(
        AppIcons.chevronRight,
        size: 18,
        color: theme.colorScheme.onSurfaceVariant,
      ),
      onTap: onTap,
    );
  }
}
