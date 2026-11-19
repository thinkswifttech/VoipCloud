import 'package:flutter/material.dart';

import '../../../shared/icons/app_icons.dart';
import '../../accounts/presentation/line_widgets.dart';
import 'settings_controller.dart';
import '../application/pbx_dnd_monitor.dart';

/// One account's own switch on the "All devices" tab.
class DndAccountSwitch {
  const DndAccountSwitch({
    required this.extension,
    required this.colorValue,
    required this.pbxState,
    required this.onChanged,
  });

  final String extension;
  final int colorValue;
  final PbxDndState pbxState;
  final ValueChanged<bool> onChanged;
}

class DndSettingsSection extends StatelessWidget {
  const DndSettingsSection({
    required this.enabled,
    required this.scope,
    required this.onEnabledChanged,
    required this.onScopeChanged,
    this.pbxState,
    this.accountSwitches = const [],
    super.key,
  });

  final bool enabled;
  final DndScope scope;
  final ValueChanged<bool> onEnabledChanged;
  final ValueChanged<DndScope> onScopeChanged;
  final PbxDndState? pbxState;

  /// With two accounts, "All devices" shows one switch each, and "This
  /// device" says it covers both.
  final List<DndAccountSwitch> accountSwitches;

  bool get _twoAccounts => accountSwitches.length > 1;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final perAccount = _twoAccounts && scope == DndScope.allDevices;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Do not disturb', style: theme.textTheme.titleMedium),
        const SizedBox(height: 12),
        SegmentedButton<DndScope>(
          segments: const [
            ButtonSegment(
              value: DndScope.thisDevice,
              icon: Icon(AppIcons.call),
              label: Text('This device'),
            ),
            ButtonSegment(
              value: DndScope.allDevices,
              icon: Icon(AppIcons.cloud),
              label: Text('All devices'),
            ),
          ],
          selected: {scope},
          showSelectedIcon: false,
          expandedInsets: EdgeInsets.zero,
          style: ButtonStyle(
            backgroundColor: WidgetStateProperty.resolveWith((states) {
              return states.contains(WidgetState.selected)
                  ? theme.colorScheme.primary
                  : Colors.transparent;
            }),
            foregroundColor: WidgetStateProperty.resolveWith((states) {
              return states.contains(WidgetState.selected)
                  ? Colors.white
                  : theme.colorScheme.onSurfaceVariant;
            }),
          ),
          onSelectionChanged: (selection) => onScopeChanged(selection.single),
        ),
        const SizedBox(height: 12),
        if (perAccount)
          for (final account in accountSwitches) ...[
            _switchTile(
              theme,
              title: Row(
                children: [
                  LineDot(colorValue: account.colorValue, size: 10),
                  const SizedBox(width: 8),
                  Flexible(child: Text('Extension ${account.extension}')),
                ],
              ),
              subtitle: account.pbxState.message,
              value: account.pbxState.enabled == true,
              onChanged: account.pbxState.canChange ? account.onChanged : null,
            ),
            const SizedBox(height: 8),
          ]
        else
          _switchTile(
            theme,
            title: const Text('Enable do not disturb'),
            subtitle: scope == DndScope.allDevices && pbxState != null
                ? 'Applies to: all devices\n${pbxState!.message}'
                : _twoAccounts
                ? 'Applies to: this device (both accounts)'
                : 'Applies to: ${scope.label.toLowerCase()}',
            value: enabled,
            onChanged:
                scope == DndScope.allDevices &&
                    pbxState != null &&
                    !pbxState!.canChange
                ? null
                : onEnabledChanged,
          ),
        const SizedBox(height: 2),
        Text(
          scope == DndScope.thisDevice
              ? _twoAccounts
                    ? 'This phone will stay silent for both accounts. Calls '
                          'will continue ringing on your other signed-in '
                          'devices.'
                    : 'Only this device will stay silent. Calls will continue '
                          'ringing on your other signed-in devices.'
              : perAccount
              ? 'Each account has its own setting. Every device signed in to '
                    'that extension will stay silent.'
              : 'Every device signed in to this extension will stay silent.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            height: 1.45,
          ),
        ),
      ],
    );
  }

  Widget _switchTile(
    ThemeData theme, {
    required Widget title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool>? onChanged,
  }) {
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: SwitchListTile.adaptive(
        title: title,
        subtitle: Text(subtitle),
        value: value,
        activeThumbColor: Colors.white,
        activeTrackColor: theme.colorScheme.primary,
        inactiveThumbColor: Colors.white,
        inactiveTrackColor: theme.brightness == Brightness.dark
            ? const Color(0xFF5C616A)
            : const Color(0xFFB8BCC4),
        onChanged: onChanged,
      ),
    );
  }
}
