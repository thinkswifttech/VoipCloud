class ResponsiveBreakpoints {
  const ResponsiveBreakpoints._();

  static bool isCompact(double width) => width < 600;
  static bool isMedium(double width) => width >= 600 && width < 1024;
  static bool isExpanded(double width) => width >= 1024;

  static double horizontalPadding(double width) {
    if (width < 420) {
      return 14;
    }
    if (width < 600) {
      return 16;
    }
    if (width < 1024) {
      return 24;
    }
    return 32;
  }
}
