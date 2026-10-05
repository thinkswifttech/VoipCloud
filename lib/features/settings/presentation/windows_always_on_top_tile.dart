import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The Windows runner owns persistence so it can restore window order before
/// Flutter's first frame, including launches into the tray.
class WindowsAlwaysOnTopTile extends StatefulWidget {
  const WindowsAlwaysOnTopTile({super.key});

  @override
  State<WindowsAlwaysOnTopTile> createState() => _WindowsAlwaysOnTopTileState();
}

class _WindowsAlwaysOnTopTileState extends State<WindowsAlwaysOnTopTile> {
  static const _channel = MethodChannel('voipcloud/windows_window');
  bool? _enabled;
  bool _busy = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      final enabled = await _channel.invokeMethod<bool>('getAlwaysOnTop');
      if (enabled == null) throw const FormatException('Missing window state');
      if (mounted) setState(() => _enabled = enabled);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _change(bool enabled) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final actual = await _channel.invokeMethod<bool>(
        'setAlwaysOnTop',
        enabled,
      );
      if (actual == null) throw const FormatException('Missing window state');
      if (mounted) setState(() => _enabled = actual);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Unable to save Always on top. Try again.'),
          ),
        );
        // Read actual state in case native rollback also failed.
        await _load();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_failed || _enabled == null) {
      return ListTile(
        title: const Text('Always on top'),
        subtitle: Text(
          _failed
              ? 'Unable to read window preference'
              : 'Loading window preference…',
        ),
        trailing: _busy
            ? const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : TextButton(onPressed: _load, child: const Text('Retry')),
      );
    }
    return SwitchListTile.adaptive(
      title: const Text('Always on top'),
      subtitle: const Text('Keep VoipCloud above other windows'),
      value: _enabled!,
      onChanged: _busy ? null : _change,
    );
  }
}
