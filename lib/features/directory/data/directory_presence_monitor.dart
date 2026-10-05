import 'dart:async';

import '../domain/directory_entry.dart';
import 'dialog_presence_parser.dart';
import 'directory_presence.dart';
import 'presence_subscription_target.dart';

/// One owner for the native subscription set. Operations are serialized and
/// superseded queued requests are discarded, including old-screen cleanup.
class DirectoryPresenceMonitor {
  DirectoryPresenceMonitor({
    required Stream<Map<String, dynamic>> events,
    required this.start,
    required this.stop,
  }) {
    _subscription = events.listen(_onEvent, onError: (_) {});
  }

  final Future<void> Function(List<String>) start;
  final Future<void> Function() stop;
  final _changes = StreamController<void>.broadcast(sync: true);
  final _dialog = <String, DirectoryPresence>{};
  final _availability = <String, DirectoryPresence>{};
  late final StreamSubscription<Map<String, dynamic>> _subscription;
  Set<String> _targets = {};
  Future<void> _writes = Future.value();
  int _generation = 0;
  bool _disposed = false;

  Stream<void> get changes => _changes.stream;

  Future<void> configure(Iterable<DirectoryEntry> entries) {
    final targets =
        entries
            .where((entry) => entry.isCompany)
            .expand((entry) => entry.numbers)
            .map((number) => number.trim())
            .where(isPresenceSubscriptionTarget)
            .toSet()
            .toList()
          ..sort();
    final generation = ++_generation;
    _targets = targets.toSet();
    _dialog.clear();
    _availability.clear();
    _writes = _writes.then((_) async {
      if (_disposed || generation != _generation) return;
      try {
        if (targets.isEmpty) {
          await stop();
        } else {
          await start(targets);
        }
      } catch (_) {
        // BLF is supplementary; no invented availability on failed subscribe.
      }
    });
    return _writes;
  }

  void _onEvent(Map<String, dynamic> event) {
    if (_disposed) return;
    final target = '${event['extension'] ?? ''}'.trim();
    if (!_targets.contains(target)) return;
    final update = parseSipPresenceEvent(event);
    if (update == null) return;
    final states = update.package == SipPresencePackage.dialog
        ? _dialog
        : _availability;
    if (states[target] == update.presence) return;
    states[target] = update.presence;
    _changes.add(null);
  }

  List<DirectoryEntry> apply(Iterable<DirectoryEntry> entries) => [
    for (final entry in entries)
      if (!entry.isCompany)
        entry
      else
        entry.copyWith(
          presence: directoryPresenceWithRegistration(
            entry: entry,
            liveStates: entry.numbers
                .map((n) => _dialog[n.trim()])
                .whereType<DirectoryPresence>(),
            availabilityStates: entry.numbers
                .map((n) => _availability[n.trim()])
                .whereType<DirectoryPresence>(),
          ),
        ),
  ];

  Future<void> dispose() async {
    _disposed = true;
    ++_generation;
    await _subscription.cancel();
    await _writes;
    try {
      await stop();
    } catch (_) {}
    await _changes.close();
  }
}
