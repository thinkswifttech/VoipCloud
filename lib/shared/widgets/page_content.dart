import 'package:flutter/material.dart';

import 'responsive.dart';

class PageContent extends StatelessWidget {
  const PageContent({
    required this.child,
    this.header,
    this.maxWidth = 920,
    this.padding = const EdgeInsets.all(20),
    this.scrollable = true,
    this.safeAreaBottom = true,
    super.key,
  });

  final Widget child;
  final Widget? header;
  final double maxWidth;
  final EdgeInsetsGeometry padding;
  final bool scrollable;
  final bool safeAreaBottom;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final horizontalPadding = ResponsiveBreakpoints.horizontalPadding(
          constraints.maxWidth,
        );
        final effectivePadding = padding == const EdgeInsets.all(20)
            ? EdgeInsets.fromLTRB(horizontalPadding, 20, horizontalPadding, 28)
            : padding;

        if (!scrollable) {
          final maxH = constraints.maxHeight.isFinite
              ? constraints.maxHeight
              : MediaQuery.sizeOf(context).height;
          final resolvedPadding = effectivePadding.resolve(
            Directionality.of(context),
          );
          final childMaxHeight = (maxH - resolvedPadding.vertical)
              .clamp(0.0, maxH)
              .toDouble();
          return SafeArea(
            bottom: safeAreaBottom,
            child: Padding(
              padding: effectivePadding,
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: maxWidth,
                    maxHeight: childMaxHeight,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (header != null) ...[
                        header!,
                        const SizedBox(height: 16),
                      ],
                      Expanded(child: child),
                    ],
                  ),
                ),
              ),
            ),
          );
        }

        return SafeArea(
          bottom: safeAreaBottom,
          child: Scrollbar(
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: effectivePadding,
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: maxWidth),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (header != null) ...[
                        header!,
                        const SizedBox(height: 16),
                      ],
                      child,
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
