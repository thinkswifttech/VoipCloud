import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../session/presentation/session_controller.dart';

Future<void> showDesktopAudioTestDialog({required BuildContext context}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const _DesktopAudioTestDialog(),
  );
}

class _DesktopAudioTestDialog extends ConsumerStatefulWidget {
  const _DesktopAudioTestDialog();

  @override
  ConsumerState<_DesktopAudioTestDialog> createState() =>
      _DesktopAudioTestDialogState();
}

class _DesktopAudioTestDialogState
    extends ConsumerState<_DesktopAudioTestDialog> {
  Timer? _meterTimer;
  double _level = 0;
  bool _starting = true;
  bool _playing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_startMeter());
  }

  @override
  void dispose() {
    _meterTimer?.cancel();
    unawaited(ref.read(sipServiceProvider).stopAudioInputTest());
    super.dispose();
  }

  Future<void> _startMeter() async {
    try {
      await ref.read(sipServiceProvider).startAudioInputTest();
      if (!mounted) return;
      setState(() => _starting = false);
      _meterTimer = Timer.periodic(
        const Duration(milliseconds: 100),
        (_) => unawaited(_sampleMeter()),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _starting = false;
        _error =
            'The microphone test could not start. Check its permission and connection.';
      });
    }
  }

  Future<void> _sampleMeter() async {
    try {
      final sample = await ref.read(sipServiceProvider).getAudioInputLevel();
      if (!mounted) return;
      // Fast attack and slower release keeps speech readable without flicker.
      final next = sample > _level ? sample : (_level * 0.72) + (sample * 0.28);
      setState(() => _level = next.clamp(0, 1));
    } catch (_) {
      _meterTimer?.cancel();
      if (!mounted) return;
      setState(() {
        _level = 0;
        _error = 'The selected microphone is no longer available.';
      });
    }
  }

  Future<void> _playSound() async {
    if (_playing) return;
    setState(() {
      _playing = true;
      _error = null;
    });
    try {
      await ref.read(sipServiceProvider).playAudioTestSound();
      await Future<void>.delayed(const Duration(milliseconds: 900));
    } catch (_) {
      if (mounted) {
        setState(() {
          _error =
              'The test sound could not play through the selected speaker.';
        });
      }
    } finally {
      if (mounted) setState(() => _playing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Test audio'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Speaker'),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _playing ? null : _playSound,
              icon: _playing
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.volume_up_rounded),
              label: Text(_playing ? 'Playing…' : 'Play test sound'),
            ),
            const SizedBox(height: 20),
            const Text('Microphone'),
            const SizedBox(height: 8),
            Semantics(
              label: 'Microphone input level',
              value: '${(_level * 100).round()} percent',
              child: ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: _starting ? null : _level,
                  minHeight: 12,
                  color: _level > 0.9
                      ? theme.colorScheme.error
                      : theme.colorScheme.primary,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _starting
                  ? 'Starting microphone…'
                  : 'Speak to check the input level.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }
}
