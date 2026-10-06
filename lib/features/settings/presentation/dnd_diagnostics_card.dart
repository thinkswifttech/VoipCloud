import 'package:flutter/material.dart';

import '../../../shared/icons/app_icons.dart';
import '../../../shared/widgets/app_card.dart';
import '../application/pbx_dnd_monitor.dart';

/// A read-only troubleshooting action; refreshing never toggles DND.
class DndDiagnosticsCard extends StatelessWidget {
  const DndDiagnosticsCard({
    required this.state,
    required this.registered,
    required this.onRefresh,
    super.key,
  });

  final PbxDndState state;
  final bool registered;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: AppCard(
        title: 'Do not disturb',
        subtitle: 'All devices',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(state.message),
            const SizedBox(height: 12),
            Tooltip(
              message:
                  'Check the current status without changing do not disturb',
              child: OutlinedButton.icon(
                onPressed: registered && !state.pending ? onRefresh : null,
                icon: const Icon(AppIcons.refresh),
                label: const Text('Refresh status'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
