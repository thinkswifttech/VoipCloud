import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/updates/desktop_update.dart';

class DesktopUpdateBadge extends ConsumerWidget {
  const DesktopUpdateBadge({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final updateAvailable = ref.watch(
      desktopUpdateProvider.select(
        (value) => value.value?.status == DesktopUpdateStatus.available,
      ),
    );
    return Badge(isLabelVisible: updateAvailable, smallSize: 9, child: child);
  }
}
