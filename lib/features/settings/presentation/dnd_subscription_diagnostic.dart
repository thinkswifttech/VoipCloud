import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/logging/log_sanitizer.dart';
import '../../../shared/widgets/app_card.dart';
import '../../../voip/platform/voip_platform_channel.dart';

/// Read-only, manually started probe. Never interprets NOTIFY as a DND command.
class DndSubscriptionDiagnostic extends StatefulWidget {
  const DndSubscriptionDiagnostic({
    required this.extension,
    required this.registered,
    required this.accountIdentity,
    this.platform = const VoipPlatformChannel(),
    this.duration = const Duration(minutes: 2),
    super.key,
  });

  final String? extension;
  final bool registered;
  final String? accountIdentity;
  final VoipPlatformChannel platform;
  final Duration duration;

  @override
  State<DndSubscriptionDiagnostic> createState() =>
      _DndSubscriptionDiagnosticState();
}

class _DndSubscriptionDiagnosticState extends State<DndSubscriptionDiagnostic> {
  StreamSubscription<Map<String, dynamic>>? _events;
  Timer? _timer;
  Future<void> _operations = Future.value();
  final List<String> _lines = [];
  bool _running = false;
  int _generation = 0;

  void _record(String text) {
    if (!mounted) return;
    final safe = LogSanitizer.sanitizeText(text);
    setState(() {
      _lines.add('${DateTime.now().toUtc().toIso8601String()} $safe');
      if (_lines.length > 30) _lines.removeAt(0);
    });
  }

  Future<void> _start() async {
    final extension = widget.extension;
    if (_running ||
        !widget.registered ||
        extension == null ||
        !RegExp(r'^[0-9]{2,8}$').hasMatch(extension)) {
      return;
    }
    final generation = ++_generation;
    final platform = widget.platform;
    setState(() {
      _running = true;
      _lines.clear();
    });
    _record('Read-only SUBSCRIBE target=*76$extension; dialog and presence');
    _events = platform.presenceEvents().listen(
      (event) {
        if (!mounted ||
            generation != _generation ||
            event['extension'] != '*76$extension') {
          return;
        }
        if (event['kind'] == 'subscription') {
          _record(
            'SUBSCRIPTION event=${event['event']} state=${event['state']}',
          );
        } else if (event['kind'] == 'notify') {
          final body = event['body']?.toString() ?? '';
          _record(
            'NOTIFY event=${event['event']} type=${event['contentType']}\n'
            '${body.length > 4096 ? body.substring(0, 4096) : body}',
          );
        }
      },
      onError: (_) {
        if (generation == _generation && mounted) {
          _record('Subscription event stream failed.');
          _stop();
        }
      },
    );
    _timer = Timer(widget.duration, () {
      if (mounted && generation == _generation) {
        _record('Test window ended.');
        _stop();
      }
    });
    // Serialize start/stop: leaving the screen during native startup cannot
    // leave a late-created subscription running.
    _operations = _operations.then((_) async {
      if (generation != _generation) return;
      try {
        await platform.startDndDiagnostic(extension);
      } catch (_) {
        if (mounted && generation == _generation) {
          _record('Unable to start subscription test.');
          _stop();
        }
      }
    });
  }

  void _stop({bool updateUi = true}) {
    ++_generation;
    _timer?.cancel();
    _timer = null;
    unawaited(_events?.cancel());
    _events = null;
    final platform = widget.platform;
    _operations = _operations.then((_) async {
      try {
        await platform.stopDndDiagnostic();
      } catch (_) {
        _record('Unable to confirm subscription cleanup.');
      }
    });
    if (updateUi && mounted) setState(() => _running = false);
  }

  @override
  void didUpdateWidget(DndSubscriptionDiagnostic oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_running &&
        (!widget.registered ||
            widget.extension != oldWidget.extension ||
            widget.accountIdentity != oldWidget.accountIdentity)) {
      _stop();
    }
  }

  @override
  void dispose() {
    _stop(updateUi: false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final usable =
        widget.registered &&
        widget.extension != null &&
        RegExp(r'^[0-9]{2,8}$').hasMatch(widget.extension!);
    return AppCard(
      title: 'All-devices DND subscription test',
      subtitle: 'Read-only PBX state diagnostic',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Keep this screen open, then enable and disable All devices DND '
            'from another device. '
            'This test does not change DND. It stops automatically after two '
            'minutes or when you leave this screen.',
          ),
          if (!usable)
            const Text('Register a numeric extension to run this test.'),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(
                onPressed: usable && !_running ? _start : null,
                child: const Text('Start DND test'),
              ),
              OutlinedButton(
                onPressed: _running ? _stop : null,
                child: const Text('Stop test'),
              ),
              OutlinedButton(
                onPressed: _lines.isEmpty
                    ? null
                    : () async {
                        await Clipboard.setData(
                          ClipboardData(text: _lines.join('\n\n')),
                        );
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Diagnostic copied')),
                          );
                        }
                      },
                child: const Text('Copy results'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(_running ? 'Listening for PBX notifications…' : 'Test stopped'),
          if (_lines.isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240),
              child: SingleChildScrollView(
                child: SelectableText(_lines.join('\n\n')),
              ),
            ),
        ],
      ),
    );
  }
}
