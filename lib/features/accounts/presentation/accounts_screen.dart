import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/route_names.dart';
import '../../../app/theme/app_theme.dart';
import '../../../shared/icons/app_icons.dart';
import '../../../shared/widgets/app_card.dart';
import '../../../shared/widgets/app_modal_bottom_sheet.dart';
import '../../../shared/widgets/page_content.dart';
import '../../../shared/widgets/status_pill.dart';
import '../../session/presentation/session_controller.dart';
import '../../sip/domain/sip_registration_state.dart';
import '../domain/account_models.dart';
import 'accounts_controller.dart';
import 'line_widgets.dart';

/// Settings > Accounts: the two lines, adding or removing the second one, and
/// which line the Call button uses.
class AccountsScreen extends ConsumerWidget {
  const AccountsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(accountsControllerProvider).value;
    final lines = ref.watch(accountLinesProvider);
    final primaryState = ref.watch(sipRegistrationStateProvider).value;
    final secondState = ref.watch(secondaryRegistrationStateProvider).value;
    final hasSecond = accounts?.hasSecondary ?? false;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Accounts'),
        leading: BackButton(
          onPressed: () => context.canPop()
              ? context.pop()
              : context.go(RoutePaths.settings),
        ),
      ),
      body: PageContent(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppCard(
              title: 'Your accounts',
              subtitle: hasSecond
                  ? 'Both accounts ring on this phone.'
                  : 'The account this phone was set up with.',
              child: Column(
                children: [
                  for (final info in lines)
                    _LineTile(
                      info: info,
                      isPrimary: info.line == AccountLine.primary,
                      state: info.line == AccountLine.primary
                          ? primaryState
                          : secondState,
                      onTap: () => _editLine(context, ref, info),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            if (!hasSecond)
              AppCard(
                title: 'Add a second account',
                subtitle:
                    'Use another phone number on this phone. You choose which one to call from, and both ring.',
                child: FilledButton.icon(
                  onPressed: () => context.push(RoutePaths.accountsAdd),
                  icon: const Icon(AppIcons.add, size: AppIconSize.md),
                  label: const Text('Add account'),
                ),
              )
            else ...[
              AppCard(
                title: 'Call from',
                subtitle:
                    'Calls you return, and messages you answer, use the same account automatically. This is for new numbers.',
                child: _DefaultLineSelector(
                  lines: lines,
                  selected: accounts!.prefs.defaultOutgoing,
                  onChanged: (value) => ref
                      .read(accountsControllerProvider.notifier)
                      .setDefaultOutgoing(value),
                ),
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: () => _confirmRemove(context, ref, lines.last.label),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.error,
                ),
                icon: const Icon(AppIcons.trash, size: AppIconSize.md),
                label: const Text('Remove second account'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _confirmRemove(
    BuildContext context,
    WidgetRef ref,
    String label,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove this account?'),
        content: Text(
          '$label will stop ringing on this phone and its saved sign-in is removed. Your call history stays.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(accountsControllerProvider.notifier).removeSecondary();
  }

  Future<void> _editLine(BuildContext context, WidgetRef ref, LineInfo info) {
    return showAppModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _EditLineSheet(info: info),
    );
  }
}

class _LineTile extends StatelessWidget {
  const _LineTile({
    required this.info,
    required this.isPrimary,
    required this.state,
    required this.onTap,
  });

  final LineInfo info;
  final bool isPrimary;
  final SipRegistrationState? state;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = lineStatus(context, state);
    final identity = info.config?.sipIdentity ?? '';
    return ListTile(
      contentPadding: EdgeInsets.zero,
      onTap: onTap,
      leading: LineDot(colorValue: info.colorValue, size: 16),
      title: Row(
        children: [
          Flexible(
            child: Text(
              info.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTheme.digits(
                theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          if (isPrimary) ...[
            const SizedBox(width: 8),
            Text('Primary', style: theme.textTheme.labelSmall),
          ],
        ],
      ),
      subtitle: Text(identity, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: StatusPill(label: status.label, color: status.color),
    );
  }
}

class _DefaultLineSelector extends StatelessWidget {
  const _DefaultLineSelector({
    required this.lines,
    required this.selected,
    required this.onChanged,
  });

  final List<LineInfo> lines;
  final DefaultOutgoingLine selected;
  final ValueChanged<DefaultOutgoingLine> onChanged;

  @override
  Widget build(BuildContext context) {
    return LineSegmented(
      lines: lines,
      allLabel: 'Ask me',
      selected: selected.line,
      onSelected: (line) => onChanged(switch (line) {
        null => DefaultOutgoingLine.ask,
        AccountLine.primary => DefaultOutgoingLine.primary,
        AccountLine.secondary => DefaultOutgoingLine.secondary,
      }),
    );
  }
}

class _EditLineSheet extends ConsumerStatefulWidget {
  const _EditLineSheet({required this.info});

  final LineInfo info;

  @override
  ConsumerState<_EditLineSheet> createState() => _EditLineSheetState();
}

class _EditLineSheetState extends ConsumerState<_EditLineSheet> {
  late final TextEditingController _name;
  late int _color;

  @override
  void initState() {
    super.initState();
    final prefs = ref.read(accountsControllerProvider).value?.prefs;
    _name = TextEditingController(
      text: prefs?.appearance(widget.info.line).label ?? '',
    );
    _color = widget.info.colorValue;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        8,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Name and colour', style: theme.textTheme.titleLarge),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            maxLength: 24,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(
              labelText: 'Name',
              hintText: widget.info.label,
              hintStyle: AppTheme.digits(null),
              helperText: 'Leave empty to use the default name.',
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final value in accountColorChoices)
                _Swatch(
                  colorValue: value,
                  selected: value == _color,
                  onTap: () => setState(() => _color = value),
                ),
            ],
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: () async {
              await ref
                  .read(accountsControllerProvider.notifier)
                  .setAppearance(
                    widget.info.line,
                    label: _name.text,
                    colorValue: _color,
                  );
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.colorValue,
    required this.selected,
    required this.onTap,
  });

  final int colorValue;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: 'Colour',
      child: InkResponse(
        onTap: onTap,
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: Color(colorValue),
            shape: BoxShape.circle,
            border: Border.all(
              color: selected
                  ? Theme.of(context).colorScheme.onSurface
                  : Colors.transparent,
              width: 3,
            ),
          ),
          child: selected
              ? const Icon(Icons.check, color: Colors.white, size: 18)
              : null,
        ),
      ),
    );
  }
}
