import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/route_names.dart';
import '../../../app/theme/app_theme.dart';
import '../../../core/files/downloads_saver.dart';
import '../../../shared/icons/app_icons.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../sip/domain/sip_log_entry.dart';
import '../../sip/presentation/sip_log_providers.dart';
import 'settings_controller.dart';

class SipLogsScreen extends ConsumerStatefulWidget {
  const SipLogsScreen({super.key});

  @override
  ConsumerState<SipLogsScreen> createState() => _SipLogsScreenState();
}

class _SipLogsScreenState extends ConsumerState<SipLogsScreen> {
  final _scrollController = ScrollController();
  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(sipLogStoreProvider).refreshFromNativeFile();
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = ref.watch(settingsControllerProvider).voipDebugLogsEnabled;
    final logs =
        ref.watch(sipLogEntriesProvider).value ?? const <SipLogEntry>[];

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
        title: const Text('SIP logs'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: () =>
                ref.read(sipLogStoreProvider).refreshFromNativeFile(),
            icon: const Icon(AppIcons.refresh),
          ),
          IconButton(
            tooltip: 'Copy all',
            onPressed: logs.isEmpty ? null : () => _copy(logs),
            icon: const Icon(AppIcons.paste),
          ),
          IconButton(
            tooltip: 'Export',
            onPressed: logs.isEmpty || _exporting ? null : _export,
            icon: const Icon(AppIcons.exportFile),
          ),
          IconButton(
            tooltip: 'Clear',
            onPressed: logs.isEmpty
                ? null
                : () => ref.read(sipLogStoreProvider).clear(),
            icon: const Icon(AppIcons.trash),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          Material(
            color: theme.colorScheme.surfaceContainerHighest.withValues(
              alpha: 0.45,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  Icon(
                    AppIcons.sipDiagnostics,
                    size: AppIconSize.sm,
                    color: enabled
                        ? const Color(0xFF16A34A)
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      enabled
                          ? 'Logging on · ${logs.length} entries'
                          : 'Logging off · showing last captured entries',
                      style: theme.textTheme.labelLarge,
                    ),
                  ),
                  Switch.adaptive(
                    value: enabled,
                    onChanged: (value) {
                      ref
                          .read(settingsControllerProvider.notifier)
                          .setVoipDebugLogsEnabled(enabled: value);
                    },
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: logs.isEmpty
                ? EmptyState(
                    icon: AppIcons.sipDiagnostics,
                    title: enabled
                        ? 'Waiting for SIP events'
                        : 'No SIP logs yet',
                    message: enabled
                        ? 'Registration, calls, and native Linphone lines will appear here — including while the app is in the background.'
                        : 'Turn on SIP logging to capture registration and call diagnostics.',
                  )
                : ListView.separated(
                    controller: _scrollController,
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                    itemCount: logs.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 6),
                    itemBuilder: (context, index) {
                      // Newest first.
                      final entry = logs[logs.length - 1 - index];
                      return _SipLogTile(entry: entry);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _copy(List<SipLogEntry> logs) async {
    final text = ref.read(sipLogStoreProvider).exportText();
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('SIP logs copied')));
  }

  Future<void> _export() async {
    setState(() => _exporting = true);
    try {
      final stamp = DateTime.now()
          .toUtc()
          .toIso8601String()
          .replaceAll(':', '')
          .replaceAll('-', '')
          .split('.')
          .first;
      final path = await AppFiles().saveText(
        fileName: 'thinkSwift_Voipcloud_sip_logs_$stamp.txt',
        content: ref.read(sipLogStoreProvider).exportText(),
        mimeType: 'text/plain',
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Saved $path')));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not export SIP logs.')),
      );
    } finally {
      if (mounted) {
        setState(() => _exporting = false);
      }
    }
  }
}

class _SipLogTile extends StatelessWidget {
  const _SipLogTile({required this.entry});

  final SipLogEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = switch (entry.level) {
      'error' => theme.colorScheme.error,
      'warn' => const Color(0xFFF59E0B),
      'debug' => theme.colorScheme.onSurfaceVariant,
      _ => theme.colorScheme.onSurface,
    };
    final time = TimeOfDay.fromDateTime(entry.at.toLocal());
    final stamp =
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:${entry.at.second.toString().padLeft(2, '0')}';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppTheme.sheetControlBackground(theme.brightness),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                stamp,
                style: AppTheme.numberStyle(
                  theme.textTheme.labelSmall,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                entry.level.toUpperCase(),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                entry.source,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          SelectableText(
            entry.message,
            style: AppTheme.numberStyle(
              theme.textTheme.bodySmall,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
