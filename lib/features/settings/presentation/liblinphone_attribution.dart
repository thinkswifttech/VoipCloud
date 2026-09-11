import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:url_launcher/url_launcher.dart' as url_launcher;

import '../../../shared/icons/app_icons.dart';
import '../../../shared/widgets/app_card.dart';

typedef ExternalUrlLauncher = Future<bool> Function(Uri uri);

class LiblinphoneAttributionTile extends StatelessWidget {
  const LiblinphoneAttributionTile({this.externalUrlLauncher, super.key});

  static final Uri sourceUri = Uri.parse(
    'https://github.com/thinkswifttech/VoipCloud/releases',
  );
  static const String bundledLicenseAsset = 'assets/legal/AGPL-3.0.txt';
  static final Uri liblinphoneUri = Uri.parse(
    'https://www.linphone.org/en/liblinphone-voip-sdk/',
  );

  final ExternalUrlLauncher? externalUrlLauncher;

  @override
  Widget build(BuildContext context) {
    return AppInfoTile(
      icon: AppIcons.info,
      title: 'Built with Liblinphone',
      subtitle: 'Open-source VoIP SDK by Belledonne Communications',
      trailing: const Icon(AppIcons.chevronRight),
      onTap: () => _showAcknowledgement(context),
    );
  }

  Future<void> _showAcknowledgement(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Open-source acknowledgements'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'VoipCloud uses Liblinphone, an open-source SIP and VoIP SDK '
                'developed by Belledonne Communications.',
              ),
              const SizedBox(height: 12),
              const Text(
                'Liblinphone and this open-source release are provided under '
                'the GNU Affero General Public License version 3.',
              ),
              const SizedBox(height: 12),
              const Text(
                'Copyright © 2026 ThinkSwift. This program is free software: '
                'you may redistribute it and/or modify it under GNU AGPLv3. '
                'It is provided without warranty, to the extent permitted by '
                'law.',
              ),
              const SizedBox(height: 12),
              Text(
                'VoipCloud is an independent application and is not endorsed '
                'by Belledonne Communications.',
                style: Theme.of(dialogContext).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              _AttributionLink(
                title: 'Source code for this version',
                subtitle: 'Open the VoipCloud public releases',
                onTap: () => _openExternal(dialogContext, sourceUri),
              ),
              _AttributionLink(
                title: 'GNU AGPLv3 license',
                subtitle: 'Read the bundled distribution license',
                onTap: () => _showBundledLicense(dialogContext),
              ),
              _AttributionLink(
                title: 'Liblinphone',
                subtitle: 'Official SDK information',
                onTap: () => _openExternal(dialogContext, liblinphoneUri),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _openExternal(BuildContext context, Uri uri) async {
    final opened =
        await (externalUrlLauncher?.call(uri) ??
            url_launcher.launchUrl(
              uri,
              mode: url_launcher.LaunchMode.externalApplication,
            ));
    if (!opened && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Unable to open the link.')));
    }
  }

  Future<void> _showBundledLicense(BuildContext context) async {
    try {
      final license = await rootBundle.loadString(bundledLicenseAsset);
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (licenseContext) => AlertDialog(
          title: const Text('GNU Affero General Public License v3'),
          content: SingleChildScrollView(child: SelectableText(license)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(licenseContext).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Unable to load the bundled license.')),
        );
      }
    }
  }
}

class _AttributionLink extends StatelessWidget {
  const _AttributionLink({
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(AppIcons.externalLink),
      title: Text(title),
      subtitle: Text(subtitle),
      onTap: onTap,
    );
  }
}
