import 'dart:async';

import '../../../core/logging/log_sanitizer.dart';
import '../../../voip/platform/voip_platform_channel.dart';
import '../domain/sip_log_entry.dart';

/// In-app SIP diagnostics log buffer.
///
/// When enabled, captures Flutter SIP status events and native Linphone lines.
/// Lines are also appended to a native file so logging continues while the app
/// is backgrounded; the viewer reloads that file on open / refresh.
class SipLogStore {
  SipLogStore({
    VoipPlatformChannel platformChannel = const VoipPlatformChannel(),
  }) : _platform = platformChannel;

  static const maxEntries = 4000;

  final VoipPlatformChannel _platform;
  final List<SipLogEntry> _entries = <SipLogEntry>[];
  final StreamController<List<SipLogEntry>> _controller =
      StreamController<List<SipLogEntry>>.broadcast();

  StreamSubscription<Map<String, dynamic>>? _nativeSubscription;
  bool _enabled = false;
  bool _hydrating = false;

  bool get isEnabled => _enabled;

  List<SipLogEntry> get entries => List<SipLogEntry>.unmodifiable(_entries);

  Stream<List<SipLogEntry>> get stream async* {
    yield entries;
    yield* _controller.stream;
  }

  Future<void> setEnabled(bool enabled) async {
    if (_enabled == enabled) {
      if (enabled) {
        await refreshFromNativeFile();
      }
      return;
    }
    _enabled = enabled;
    try {
      await _platform.setSipLoggingEnabled(enabled);
    } catch (_) {
      // Native bridge may be unavailable on unsupported platforms.
    }
    if (enabled) {
      _bindNativeLogs();
      append(level: 'info', source: 'app', message: 'SIP logging enabled');
      await refreshFromNativeFile();
    } else {
      await _nativeSubscription?.cancel();
      _nativeSubscription = null;
      append(
        level: 'info',
        source: 'app',
        message: 'SIP logging disabled',
        persist: false,
      );
      try {
        await _platform.setSipLoggingEnabled(false);
      } catch (_) {}
      _emit();
    }
  }

  void append({
    required String level,
    required String source,
    required String message,
    bool persist = true,
  }) {
    if (!_enabled && source != 'app') {
      return;
    }
    final sanitized = LogSanitizer.sanitizeText(message).trim();
    if (sanitized.isEmpty) {
      return;
    }
    final entry = SipLogEntry(
      at: DateTime.now(),
      level: SipLogEntry.normalizeLevel(level),
      source: source,
      message: sanitized,
    );
    _entries.add(entry);
    _trim();
    _emit();
    if (_enabled && persist) {
      unawaited(_platform.appendSipLogLine(entry.line).catchError((_) => null));
    }
  }

  void info(String message, {String source = 'sip'}) {
    append(level: 'info', source: source, message: message);
  }

  void warn(String message, {String source = 'sip'}) {
    append(level: 'warn', source: source, message: message);
  }

  void error(String message, {String source = 'sip'}) {
    append(level: 'error', source: source, message: message);
  }

  void debug(String message, {String source = 'sip'}) {
    append(level: 'debug', source: source, message: message);
  }

  Future<void> clear() async {
    _entries.clear();
    _emit();
    try {
      await _platform.clearSipLogFile();
    } catch (_) {}
    if (_enabled) {
      append(level: 'info', source: 'app', message: 'SIP logs cleared');
    }
  }

  Future<void> refreshFromNativeFile() async {
    if (_hydrating) {
      return;
    }
    _hydrating = true;
    try {
      final text = await _platform.readSipLogFile();
      if (text.trim().isEmpty) {
        return;
      }
      final imported = <SipLogEntry>[];
      for (final raw in text.split('\n')) {
        final line = raw.trim();
        if (line.isEmpty) {
          continue;
        }
        imported.add(_parsePersistedLine(line));
      }
      if (imported.isEmpty) {
        return;
      }
      _entries
        ..clear()
        ..addAll(imported);
      _trim();
      _emit();
    } catch (_) {
      // File may not exist yet.
    } finally {
      _hydrating = false;
    }
  }

  String exportText() {
    if (_entries.isEmpty) {
      return 'VoipCloud SIP logs\n(no entries)\n';
    }
    final buffer = StringBuffer()
      ..writeln('VoipCloud SIP logs')
      ..writeln('Exported: ${DateTime.now().toUtc().toIso8601String()}')
      ..writeln('Entries: ${_entries.length}')
      ..writeln('---');
    for (final entry in _entries) {
      buffer.writeln(entry.line);
    }
    return buffer.toString();
  }

  void dispose() {
    unawaited(_nativeSubscription?.cancel());
    _nativeSubscription = null;
    _controller.close();
  }

  void _bindNativeLogs() {
    _nativeSubscription?.cancel();
    _nativeSubscription = _platform.sipLogEvents().listen((event) {
      if (!_enabled) {
        return;
      }
      final entry = SipLogEntry.fromMap(event);
      final sanitized = LogSanitizer.sanitizeText(entry.message).trim();
      if (sanitized.isEmpty) {
        return;
      }
      // Native already persists; avoid double-writing the file.
      _entries.add(
        SipLogEntry(
          at: entry.at,
          level: entry.level,
          source: entry.source,
          message: sanitized,
        ),
      );
      _trim();
      _emit();
    }, onError: (_) {});
  }

  SipLogEntry _parsePersistedLine(String line) {
    // Expected: 2026-07-28T16:00:00.000Z [INFO] [source] message
    final match = RegExp(
      r'^(\S+)\s+\[(\w+)\]\s+\[([^\]]+)\]\s+(.*)$',
    ).firstMatch(line);
    if (match != null) {
      return SipLogEntry(
        at: DateTime.tryParse(match.group(1)!) ?? DateTime.now(),
        level: SipLogEntry.normalizeLevel(match.group(2)!),
        source: match.group(3)!.trim(),
        message: LogSanitizer.sanitizeText(match.group(4)!),
      );
    }
    return SipLogEntry(
      at: DateTime.now(),
      level: 'info',
      source: 'native-file',
      message: LogSanitizer.sanitizeText(line),
    );
  }

  void _trim() {
    final overflow = _entries.length - maxEntries;
    if (overflow > 0) {
      _entries.removeRange(0, overflow);
    }
  }

  void _emit() {
    if (!_controller.isClosed) {
      _controller.add(entries);
    }
  }
}
