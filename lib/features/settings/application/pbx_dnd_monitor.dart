import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:xml/xml.dart';

class PbxDndState {
  const PbxDndState({
    this.enabled,
    this.pending = false,
    this.message = 'Do not disturb status unavailable',
  });
  final bool? enabled;
  final bool pending;
  final String message;
  bool get canChange => enabled != null && !pending;
}

class DndDialogUpdate {
  const DndDialogUpdate(this.version, this.enabled, {this.full = true});
  final int version;
  final bool enabled;
  final bool full;
}

/// Only full state for the dedicated DND hint is authoritative, never BLF.
DndDialogUpdate? parseDndDialog(String body, String target, String domain) {
  if (body.length > 16384 || body.contains('<!DOCTYPE')) return null;
  try {
    final root = XmlDocument.parse(body).rootElement;
    if (root.name.local != 'dialog-info' ||
        root.namespaceUri != 'urn:ietf:params:xml:ns:dialog-info' ||
        !const {'full', 'partial'}.contains(root.getAttribute('state')) ||
        root.getAttribute('entity')?.toLowerCase() !=
            'sip:$target@$domain'.toLowerCase()) {
      return null;
    }
    final version = int.tryParse(root.getAttribute('version') ?? '');
    if (version == null || version < 0) return null;
    // Request a new full snapshot instead of guessing from a partial document.
    if (root.getAttribute('state') == 'partial') {
      return DndDialogUpdate(version, false, full: false);
    }
    final dialogs = root.childElements
        .where(
          (e) =>
              e.name.local == 'dialog' && e.namespaceUri == root.namespaceUri,
        )
        .toList();
    if (dialogs.length != 1 || dialogs.single.getAttribute('id') != target) {
      return null;
    }
    final states = dialogs.single.childElements
        .where(
          (e) => e.name.local == 'state' && e.namespaceUri == root.namespaceUri,
        )
        .toList();
    if (states.length != 1) return null;
    return switch (states.single.innerText.trim()) {
      'confirmed' => DndDialogUpdate(version, true),
      'terminated' => DndDialogUpdate(version, false),
      _ => null,
    };
  } catch (_) {
    return null;
  }
}

/// One installation-wide owner, independent of Directory/Settings navigation.
class PbxDndMonitor extends ChangeNotifier {
  PbxDndMonitor({
    required Stream<Map<String, dynamic>> events,
    required this.start,
    required this.stop,
    required this.toggle,
    required this.canToggle,
    this.diagnostic,
    this.confirmationTimeout = const Duration(seconds: 15),
    this.initialTimeout = const Duration(seconds: 15),
    this.renewAfter = const Duration(minutes: 4),
    this.retryBase = const Duration(seconds: 2),
  }) {
    _events = events.listen(
      _onEvent,
      onError: (_) => _failed('Unable to check do not disturb. Reconnecting…'),
    );
  }
  final Future<void> Function(String extension, String subscriptionId) start;
  final Future<void> Function() stop, toggle;
  final bool Function() canToggle;
  final void Function(String message)? diagnostic;
  final Duration confirmationTimeout, initialTimeout, renewAfter, retryBase;
  late final StreamSubscription<Map<String, dynamic>> _events;
  Future<void> _operations = Future.value();
  Timer? _retry, _initial, _renew, _confirmation;
  String? _identity, _extension, _domain, _subscriptionId;
  bool _registered = false, _disposed = false;
  int _generation = 0, _version = -1, _failures = 0;
  bool? _desired;
  bool? _unconfirmedDesired;
  PbxDndState state = const PbxDndState();

  void _publish(PbxDndState next) {
    if (_disposed) return;
    state = next;
    notifyListeners();
  }

  void configure({
    required String? identity,
    required String? extension,
    required String? domain,
    required bool registered,
  }) {
    if (_disposed) return;
    registered =
        registered &&
        extension != null &&
        RegExp(r'^[0-9]{2,8}$').hasMatch(extension) &&
        domain != null &&
        domain.isNotEmpty &&
        identity != null;
    if (_identity == identity && _registered == registered) return;
    _identity = identity;
    _extension = extension;
    _domain = domain;
    _registered = registered;
    _failures = 0;
    _unconfirmedDesired = null;
    refresh();
  }

  void refresh({String? message}) {
    if (_disposed) return;
    _retry?.cancel();
    _initial?.cancel();
    _renew?.cancel();
    _confirmation?.cancel();
    _retry = null;
    _renew = null;
    _desired = null;
    final generation = ++_generation;
    _version = -1;
    final id = '${DateTime.now().microsecondsSinceEpoch}-$generation';
    _subscriptionId = id;
    _publish(
      PbxDndState(
        message:
            message ??
            (_registered
                ? 'Checking do not disturb…'
                : 'Connect to calling to check do not disturb'),
      ),
    );
    final extension = _extension;
    _operations = _operations.then((_) async {
      try {
        await stop().timeout(const Duration(seconds: 5));
        if (_disposed ||
            generation != _generation ||
            !_registered ||
            extension == null) {
          return;
        }
        _initial = Timer(initialTimeout, () {
          if (generation == _generation) {
            _failed('Unable to check do not disturb. Reconnecting…');
          }
        });
        await start(extension, id).timeout(const Duration(seconds: 5));
      } catch (_) {
        if (generation == _generation) {
          _failed('Unable to check do not disturb. Reconnecting…');
        }
      }
    });
  }

  void _failed(String message) {
    if (_disposed || !_registered || _retry?.isActive == true) return;
    _initial?.cancel();
    _renew?.cancel();
    _confirmation?.cancel();
    _desired = null;
    _publish(PbxDndState(message: message));
    _subscriptionId = null;
    final factor = 1 << (_failures++).clamp(0, 5);
    _retry = Timer(
      Duration(
        milliseconds: (retryBase.inMilliseconds * factor).clamp(1, 60000),
      ),
      refresh,
    );
  }

  void _onEvent(Map<String, dynamic> event) {
    if (_disposed ||
        !_registered ||
        _subscriptionId == null ||
        event['subscriptionId'] != _subscriptionId ||
        event['extension'] != '*76$_extension' ||
        event['event'] != 'dialog') {
      return;
    }
    if (event['kind'] == 'subscription') {
      if (event['state'] == 'error' || event['state'] == 'terminated') {
        _failed('Do not disturb connection lost. Reconnecting…');
      }
      return;
    }
    if (event['kind'] != 'notify' ||
        event['contentType'] != 'application/dialog-info+xml') {
      return;
    }
    final update = parseDndDialog(
      event['body']?.toString() ?? '',
      '*76$_extension',
      _domain!,
    );
    if (update == null || update.version <= _version) return;
    if (!update.full) {
      _failed('Refreshing do not disturb status…');
      return;
    }
    _version = update.version;
    diagnostic?.call(
      'DND state received enabled=${update.enabled} version=${update.version} pending=${_desired != null}',
    );
    _failures = 0;
    _initial?.cancel();
    _renew ??= Timer(renewAfter, () {
      if (_desired != null) {
        _renew = Timer(confirmationTimeout, refresh);
      } else {
        refresh();
      }
    });
    if (_desired == update.enabled) {
      _desired = null;
      _confirmation?.cancel();
    }
    if (_unconfirmedDesired == update.enabled) _unconfirmedDesired = null;
    _publish(
      PbxDndState(
        enabled: update.enabled,
        pending: _desired != null,
        message: _desired != null
            ? 'Updating do not disturb…'
            : _unconfirmedDesired != null
            ? 'Could not confirm your change. Do not disturb is still ${update.enabled ? "on" : "off"}.'
            : 'Do not disturb is ${update.enabled ? "on" : "off"} for all devices',
      ),
    );
  }

  Future<void> setEnabled(bool enabled) async {
    if (_disposed || !state.canChange || !_registered) return;
    if (!canToggle()) {
      _publish(
        PbxDndState(
          enabled: state.enabled,
          message:
              'End the current call before changing do not disturb on all devices',
        ),
      );
      return;
    }
    if (enabled == state.enabled) return;
    final generation = _generation;
    _unconfirmedDesired = null;
    _desired = enabled;
    diagnostic?.call('DND change requested enabled=$enabled');
    _publish(
      PbxDndState(
        enabled: state.enabled,
        pending: true,
        message: 'Updating do not disturb…',
      ),
    );
    _confirmation = Timer(confirmationTimeout, () {
      if (_disposed || generation != _generation || _desired == null) return;
      _unconfirmedDesired = _desired;
      diagnostic?.call(
        'DND change confirmation timed out; checking state without redial',
      );
      _desired = null;
      refresh(message: 'Change not confirmed. Checking do not disturb…');
      // Never retry *76: it might already have reached the PBX.
    });
    try {
      await toggle();
    } catch (_) {
      if (_disposed || generation != _generation || _desired == null) return;
      _desired = null;
      _confirmation?.cancel();
      _publish(
        PbxDndState(
          enabled: state.enabled,
          message: 'Unable to change do not disturb. Please try again.',
        ),
      );
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    ++_generation;
    _retry?.cancel();
    _initial?.cancel();
    _renew?.cancel();
    _confirmation?.cancel();
    unawaited(_events.cancel());
    _operations = _operations.then((_) async {
      try {
        await stop();
      } catch (_) {}
    });
    super.dispose();
  }
}
