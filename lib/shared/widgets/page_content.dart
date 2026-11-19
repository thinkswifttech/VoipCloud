import 'package:flutter/material.dart';

import '../platform/desktop_platform.dart';
import 'responsive.dart';

class PageContent extends StatelessWidget {
  const PageContent({
    required this.child,
    this.header,
    this.maxWidth = 920,
    this.desktopMaxWidth,
    this.padding = const EdgeInsets.all(20),
    this.scrollable = true,
    this.safeAreaBottom = true,
    super.key,
  });

  final Widget child;
  final Widget? header;
  final double maxWidth;
  final double? desktopMaxWidth;
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
        final effectiveMaxWidth =
            desktopMaxWidth != null &&
                isSupportedDesktopPlatform() &&
                ResponsiveBreakpoints.isExpanded(constraints.maxWidth)
            ? desktopMaxWidth!
            : maxWidth;
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
                    maxWidth: effectiveMaxWidth,
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
          child: _PageScroll(
            padding: effectivePadding,
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: effectiveMaxWidth),
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
        );
      },
    );
  }
}

/// Scrolls the page and draws its scrollbar from one controller. Desktop
/// platforms do not link a Scrollbar to a scroll view automatically, which
/// raised "ScrollController has no ScrollPosition attached" on every scroll.
class _PageScroll extends StatefulWidget {
  const _PageScroll({required this.padding, required this.child});

  final EdgeInsetsGeometry padding;
  final Widget child;

  @override
  State<_PageScroll> createState() => _PageScrollState();
}

class _PageScrollState extends State<_PageScroll> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scrollbar(
      controller: _controller,
      child: SingleChildScrollView(
        controller: _controller,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: widget.padding,
        child: widget.child,
      ),
    );
  }
}
