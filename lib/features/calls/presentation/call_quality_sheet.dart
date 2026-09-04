import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../../../shared/icons/app_icons.dart';
import '../../session/presentation/session_controller.dart';
import '../domain/call_quality_info.dart';

Future<void> showCallQualitySheet({
  required BuildContext context,
  required WidgetRef ref,
  required String callId,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    builder: (_) => _CallQualitySheet(callId: callId),
  );
}

class _CallQualitySheet extends ConsumerStatefulWidget {
  const _CallQualitySheet({required this.callId});

  final String callId;

  @override
  ConsumerState<_CallQualitySheet> createState() => _CallQualitySheetState();
}

class _CallQualitySheetState extends ConsumerState<_CallQualitySheet> {
  CallQualityInfo? _info;
  String? _error;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _refresh();
    _refreshTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _refresh();
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final info = await ref
          .read(sipServiceProvider)
          .getCallQuality(callId: widget.callId);
      if (!mounted) return;
      setState(() {
        _info = info;
        _error = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Call quality is unavailable right now.';
      });
    }
  }

  Future<void> _copy() async {
    final info = _info;
    if (info == null) return;
    await Clipboard.setData(ClipboardData(text: info.toSupportText()));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Call quality copied')));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final info = _info;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        4,
        20,
        20 + MediaQuery.paddingOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Call quality', style: theme.textTheme.titleLarge),
              ),
              if (info != null)
                IconButton(
                  tooltip: 'Copy for support',
                  onPressed: _copy,
                  icon: const Icon(AppIcons.paste, size: AppIconSize.sm),
                ),
              IconButton(
                tooltip: 'Refresh',
                onPressed: _refresh,
                icon: const Icon(AppIcons.refresh, size: AppIconSize.sm),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (_error != null)
            Text(
              _error!,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
            )
          else if (info == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: CircularProgressIndicator()),
            )
          else ...[
            _QualityBadge(info: info),
            const SizedBox(height: 14),
            _MetricRow(
              label: 'MOS (current)',
              value: info.formatScore(info.currentQuality),
            ),
            _MetricRow(
              label: 'MOS (average)',
              value: info.formatScore(info.averageQuality),
            ),
            _MetricRow(label: 'Round-trip', value: _ms(info.roundTripMs)),
            _MetricRow(label: 'Jitter buffer', value: _ms(info.jitterBufferMs)),
            _MetricRow(
              label: 'Packet loss (recv)',
              value: _percent(info.receiverLossPercent),
            ),
            _MetricRow(
              label: 'Packet loss (send)',
              value: _percent(info.senderLossPercent),
            ),
            _MetricRow(
              label: 'Packet loss (local)',
              value: _percent(info.localLossPercent),
            ),
            _MetricRow(
              label: 'Bitrate down / up',
              value: _bitrate(info.downloadKbps, info.uploadKbps),
            ),
            _MetricRow(
              label: 'Codec',
              value: info.codec?.trim().isNotEmpty == true
                  ? info.codec!.trim()
                  : '—',
            ),
            _MetricRow(
              label: 'Audio route',
              value: _routeLabel(info.audioRoute),
            ),
            _MetricRow(
              label: 'Duration',
              value: _duration(info.durationSeconds),
            ),
            if (info.callId.trim().isNotEmpty)
              _MetricRow(
                label: 'Call ID',
                value: info.callId.trim(),
                mono: true,
              ),
            if (info.remoteUri != null && info.remoteUri!.trim().isNotEmpty)
              _MetricRow(
                label: 'Remote',
                value: info.remoteUri!.trim(),
                mono: true,
              ),
          ],
        ],
      ),
    );
  }
}

class _QualityBadge extends StatelessWidget {
  const _QualityBadge({required this.info});

  final CallQualityInfo info;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _qualityColor(info.currentQuality);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.sheetControlBackground(theme.brightness),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(AppIcons.sipDiagnostics, color: color, size: AppIconSize.md),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              info.qualityLabel,
              style: theme.textTheme.titleMedium?.copyWith(
                color: color,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Text(
            info.formatScore(info.currentQuality),
            style: AppTheme.numberStyle(
              theme.textTheme.titleMedium,
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricRow extends StatelessWidget {
  const _MetricRow({
    required this.label,
    required this.value,
    this.mono = false,
  });

  final String label;
  final String value;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 140,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: mono
                  ? AppTheme.numberStyle(
                      theme.textTheme.bodyMedium,
                      fontWeight: FontWeight.w600,
                    )
                  : theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

Color _qualityColor(double? score) {
  if (score == null || score < 0) {
    return const Color(0xFF9CA3AF);
  }
  if (score >= 4) return const Color(0xFF16A34A);
  if (score >= 3) return const Color(0xFFF59E0B);
  return const Color(0xFFDC2626);
}

String _ms(double? value) {
  if (value == null || value < 0) return '—';
  if (value < 10) {
    return '${value.toStringAsFixed(1)} ms';
  }
  return '${value.round()} ms';
}

String _percent(double? value) {
  if (value == null || value < 0) return '—';
  return '${value.toStringAsFixed(1)}%';
}

String _bitrate(double? down, double? up) {
  final downLabel = down == null || down < 0 ? '—' : '${down.round()} kbps';
  final upLabel = up == null || up < 0 ? '—' : '${up.round()} kbps';
  return '$downLabel / $upLabel';
}

String _duration(int? seconds) {
  if (seconds == null || seconds < 0) return '—';
  final mins = seconds ~/ 60;
  final secs = (seconds % 60).toString().padLeft(2, '0');
  if (mins >= 60) {
    final hours = mins ~/ 60;
    final remMins = (mins % 60).toString().padLeft(2, '0');
    return '$hours:$remMins:$secs';
  }
  return '$mins:$secs';
}

String _routeLabel(String? route) {
  return switch (route?.trim().toLowerCase()) {
    'speaker' => 'Speaker',
    'bluetooth' => 'Bluetooth',
    'earpiece' => 'Audio',
    null || '' => '—',
    final other => other,
  };
}
