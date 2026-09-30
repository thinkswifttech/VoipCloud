import 'package:flutter/material.dart';

import '../platform/desktop_platform.dart';

Future<T?> showAppModalBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = false,
  bool useSafeArea = false,
  bool? showDragHandle,
  Color? backgroundColor,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: isScrollControlled,
    useSafeArea: useSafeArea,
    showDragHandle: showDragHandle,
    backgroundColor: backgroundColor,
    builder: isDesktopPlatform
        ? (sheetContext) => _DesktopSheetFrame(
            onClose: () => Navigator.of(sheetContext).pop(),
            child: builder(sheetContext),
          )
        : builder,
  );
}

class _DesktopSheetFrame extends StatelessWidget {
  const _DesktopSheetFrame({required this.child, required this.onClose});

  final Widget child;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Stack(
      children: [
        Padding(padding: const EdgeInsets.only(top: 48), child: child),
        Positioned(
          top: 4,
          right: 8,
          child: IconButton(
            tooltip: 'Close',
            onPressed: onClose,
            style: IconButton.styleFrom(
              backgroundColor: colors.surfaceContainerHighest,
              foregroundColor: colors.onSurfaceVariant,
            ),
            icon: const Icon(Icons.close_rounded),
          ),
        ),
      ],
    );
  }
}
