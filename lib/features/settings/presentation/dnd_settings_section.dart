import 'package:flutter/material.dart';

import '../../../shared/icons/app_icons.dart';
import 'settings_controller.dart';

class DndSettingsSection extends StatelessWidget {
  const DndSettingsSection({
    required this.enabled,
    required this.scope,
    required this.onEnabledChanged,
    required this.onScopeChanged,
    super.key,
  });

  final bool enabled;
  final DndScope scope;
  final ValueChanged<bool> onEnabledChanged;
  final ValueChanged<DndScope> onScopeChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
        DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: theme.colorScheme.outlineVariant),
            borderRadius: BorderRadius.circular(12),
          ),
          child: SwitchListTile.adaptive(
            title: const Text('Enable do not disturb'),
            subtitle: Text('Applies to: ${scope.label.toLowerCase()}'),
            value: enabled,
            activeThumbColor: Colors.white,
            activeTrackColor: theme.colorScheme.primary,
            inactiveThumbColor: Colors.white,
            inactiveTrackColor: theme.brightness == Brightness.dark
                ? const Color(0xFF5C616A)
                : const Color(0xFFB8BCC4),
            onChanged: onEnabledChanged,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          scope == DndScope.thisDevice
              ? 'Only this device will stay silent. Calls will continue '
                    'ringing on your other signed-in devices.'
              : 'Every device signed in to this extension will stay silent.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            height: 1.45,
          ),
        ),
      ],
    );
  }
}
