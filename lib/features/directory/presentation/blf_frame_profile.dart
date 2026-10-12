import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Profile-build diagnostics only. Never stores contacts or network identifiers.
class BlfFrameProfile {
  BlfFrameProfile({required double refreshRate})
    : _budgetUs = 1000000 / (refreshRate > 0 ? refreshRate : 60) {
    WidgetsBinding.instance.addTimingsCallback(_record);
    _reportTimer = Timer.periodic(const Duration(seconds: 5), (_) => _report());
  }

  final double _budgetUs;
  late final Timer _reportTimer;
  Timer? _quietTimer;
  bool _scrolling = false;
  int _frames = 0;
  int _overBudget = 0;
  int _worstBuildUs = 0;
  int _worstRasterUs = 0;

  void setScrolling(bool value) {
    _quietTimer?.cancel();
    if (value) {
      _scrolling = true;
    } else {
      _quietTimer = Timer(const Duration(milliseconds: 200), () {
        _scrolling = false;
      });
    }
  }

  void _record(List<FrameTiming> timings) {
    if (!_scrolling) return;
    for (final frame in timings) {
      _frames++;
      final build = frame.buildDuration.inMicroseconds;
      final raster = frame.rasterDuration.inMicroseconds;
      if (build > _budgetUs || raster > _budgetUs) _overBudget++;
      if (build > _worstBuildUs) _worstBuildUs = build;
      if (raster > _worstRasterUs) _worstRasterUs = raster;
    }
  }

  void _report() {
    if (!kProfileMode || _frames == 0) return;
    final counters = {
      'frames': _frames,
      'overBudget': _overBudget,
      'overBudgetPercent': (_overBudget * 100 / _frames).toStringAsFixed(2),
      'budgetUs': _budgetUs.round(),
      'worstBuildUs': _worstBuildUs,
      'worstRasterUs': _worstRasterUs,
    };
    // AppLogger intentionally suppresses informational logs in profile mode.
    // These counters contain timing/counts only and never run in release.
    debugPrint('BLF scroll performance (profile) $counters');
  }

  void dispose() {
    WidgetsBinding.instance.removeTimingsCallback(_record);
    _reportTimer.cancel();
    _quietTimer?.cancel();
    _report();
  }
}
