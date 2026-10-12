import 'dart:async';

import '../../../core/logging/app_logger.dart';
import '../domain/directory_entry.dart';
import 'blf_feed_client.dart';
import 'dialog_presence_parser.dart';
import 'directory_presence.dart';
import 'directory_presence_cache.dart';
import 'presence_subscription_target.dart';

typedef PresenceReconciler =
    Future<void> Function(
      List<String> orderedTargets,
      List<String> additions,
      int generation,
    );

class _PresenceObservation {
  const _PresenceObservation({
    required this.presence,
    required this.observedAt,
    required this.fresh,
  });

  final DirectoryPresence presence;
  final DateTime observedAt;
  final bool fresh;

  _PresenceObservation asStale() => _PresenceObservation(
    presence: presence,
    observedAt: observedAt,
    fresh: false,
  );
}

/// Account-session owner for the ordinary BLF subscription set.
///
/// Directory pages only observe this object. Navigation never clears states or
/// tears down native subscriptions; only target/account reconciliation does.
class DirectoryPresenceMonitor {
  DirectoryPresenceMonitor({
    required Stream<Map<String, dynamic>> events,
    required this.reconcile,
    required this.stop,
    this.setTargets,
    this.cache,
    this.feed,
    this.feedFallbackDelay = const Duration(seconds: 10),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    _subscription = events.listen(_onEvent, onError: (_) {});
    _feedSubscription = feed?.events.listen(_onFeedEvent, onError: (_) {});
  }

  final PresenceReconciler reconcile;
  final Future<void> Function() stop;
  final Future<void> Function(List<String> targets, int generation)? setTargets;
  final DirectoryPresenceCache? cache;

  /// Optional server-fed BLF source. While it is authoritative, SIP presence
  /// subscriptions are not run; without it behaviour is SIP only.
  final BlfFeedSource? feed;
  final Duration feedFallbackDelay;
  final DateTime Function() _now;
  final _changes = StreamController<void>.broadcast(sync: true);
  final _dialog = <String, _PresenceObservation>{};
  final _availability = <String, _PresenceObservation>{};
  late final StreamSubscription<Map<String, dynamic>> _subscription;
  StreamSubscription<BlfFeedEvent>? _feedSubscription;
  bool _feedAuthoritative = false;
  bool _sipFallback = false;
  Timer? _feedFallbackTimer;
  final Set<String> _feedSourced = {};
  Set<String> _targets = {};
  String? _identityKey;
  bool _registered = false;
  Set<String> _requestedTargets = {};
  String? _requestedIdentityKey;
  bool _requestedRegistered = false;
  Future<void> _writes = Future.value();
  int _requestGeneration = 0;
  int _nativeGeneration = 0;
  bool _disposed = false;
  Timer? _cacheWriteTimer;
  Timer? _changeTimer;
  int _activationGeneration = 0;
  final Map<String, int> _pendingActivations = {};
  Completer<void>? _activationCompleter;
  final Set<String> _failedTargets = {};
  Timer? _retryTimer;
  int _retryAttempt = 0;
  DateTime? _convergenceStartedAt;
  Set<String> _awaitingAuthoritative = {};
  bool _firstAuthoritativeLogged = false;
  List<String> _startupPriority = const [];
  List<String> _visiblePriority = const [];
  bool _scrolling = false;
  Timer? _scrollIdleTimer;

  void setScrolling(bool scrolling) {
    if (_disposed) return;
    _scrollIdleTimer?.cancel();
    if (scrolling) {
      _scrolling = true;
    } else {
      _scrollIdleTimer = Timer(const Duration(milliseconds: 200), () {
        _scrolling = false;
      });
    }
  }

  Stream<void> get changes => _changes.stream;

  /// SIP presence runs unless a feed exists and has not been given up on.
  bool get _sipAllowed => feed == null || _sipFallback;

  /// A scheduling hint only: never restarts or duplicates a subscription.
  void prioritizeVisibleTargets(Iterable<String> targets) {
    if (_disposed) return;
    _visiblePriority = targets
        .where(_targets.contains)
        .toSet()
        .take(8)
        .toList();
  }

  Future<void> configure({
    required Iterable<DirectoryEntry> entries,
    required String? identityKey,
    required bool registered,
    Iterable<String> startupPriorityTargets = const [],
  }) {
    final allTargets = entries
        .where((entry) => entry.isCompany)
        .expand((entry) => entry.numbers)
        .map((number) => number.trim())
        .where(isPresenceSubscriptionTarget)
        .toSet();
    final orderedAllTargets = allTargets.toList()..sort();
    if (orderedAllTargets.length > 250) {
      AppLogger.warning(
        'BLF target limit exceeded; monitoring the first 250 extensions',
        data: {'requested': orderedAllTargets.length, 'limit': 250},
      );
    }
    final targets = orderedAllTargets.take(250).toSet();
    _startupPriority = startupPriorityTargets
        .where(targets.contains)
        .toSet()
        .take(8)
        .toList();
    final normalizedIdentity = identityKey?.trim();
    final effectiveIdentity =
        normalizedIdentity == null || normalizedIdentity.isEmpty
        ? null
        : normalizedIdentity;
    if (_sameTargets(targets, _requestedTargets) &&
        effectiveIdentity == _requestedIdentityKey &&
        registered == _requestedRegistered) {
      return _writes;
    }
    _requestedTargets = targets;
    _requestedIdentityKey = effectiveIdentity;
    _requestedRegistered = registered;
    final requestGeneration = ++_requestGeneration;
    if (_activationCompleter?.isCompleted == false) {
      _activationCompleter?.complete();
    }

    _writes = _writes.catchError((_) {}).then((_) async {
      if (_disposed || requestGeneration != _requestGeneration) return;
      final identityChanged = effectiveIdentity != _identityKey;
      final targetsChanged = !_sameTargets(targets, _targets);
      final becameRegistered = registered && !_registered;

      if (identityChanged) {
        _visiblePriority = const [];
        if (_identityKey != null) {
          try {
            await stop();
          } catch (_) {}
        }
        _identityKey = effectiveIdentity;
        _targets = {};
        _dialog.clear();
        _availability.clear();
        _failedTargets.clear();
        _feedSourced.clear();
        _feedAuthoritative = false;
        _sipFallback = false;
        _feedFallbackTimer?.cancel();
        _retryTimer?.cancel();
        _retryAttempt = 0;
        _registered = false;
        _cacheWriteTimer?.cancel();
        if (effectiveIdentity == null) {
          try {
            await cache?.clear();
          } catch (_) {}
          _notifyChanged();
          return;
        }
        await _restoreCache(effectiveIdentity);
      }

      if (_disposed || requestGeneration != _requestGeneration) return;
      final previousTargets = _targets;
      final removed = _targets.difference(targets);
      final added = targets.difference(previousTargets);
      _targets = targets;
      for (final target in removed) {
        _dialog.remove(target);
        _availability.remove(target);
        _failedTargets.remove(target);
        _feedSourced.remove(target);
      }
      if (feed != null && (identityChanged || targetsChanged)) {
        feed!.setTargets(effectiveIdentity == null ? const {} : targets);
        if (targets.isNotEmpty) _armFeedFallback();
      }

      if (_registered && !registered) {
        _retryTimer?.cancel();
        _markAllStale();
      }
      _registered = registered;
      if (identityChanged || targetsChanged || removed.isNotEmpty) {
        _notifyChanged();
        _scheduleCacheWrite();
      }

      if (!registered || effectiveIdentity == null) return;
      if (!identityChanged && !targetsChanged && !becameRegistered) return;
      if (!_sipAllowed) return;

      final ordered = _prioritizedTargets(targets);
      final nativeGeneration = ++_nativeGeneration;
      final additions = identityChanged || becameRegistered
          ? ordered
          : ordered.where(added.contains).toList(growable: false);
      _beginConvergence(additions);
      AppLogger.info(
        'BLF reconcile',
        data: {
          'desired': ordered.length,
          'retained': ordered.length - additions.length,
          'added': additions.length,
          'removed': removed.length,
          'queueDepth': additions.length * 2,
          'generation': nativeGeneration,
        },
      );
      try {
        await _reconcileInBatches(
          ordered,
          nativeGeneration,
          requestGeneration,
          additions: additions,
        );
      } catch (error, stackTrace) {
        _markAllStale();
        AppLogger.error(
          'BLF reconciliation failed',
          error: error,
          stackTrace: stackTrace,
        );
      }
    });
    return _writes;
  }

  Future<void> _reconcileInBatches(
    List<String> desired,
    int nativeGeneration,
    int requestGeneration, {
    List<String>? additions,
  }) async {
    final queuedAdditions = (additions ?? desired).toSet();
    await setTargets?.call(desired, nativeGeneration);
    if (desired.isEmpty || queuedAdditions.isEmpty) {
      if (setTargets == null) {
        await reconcile(desired, const [], nativeGeneration);
      }
      return;
    }
    final clock = Stopwatch()..start();
    _activationGeneration = nativeGeneration;
    _pendingActivations.clear();
    var lastStart = -250;
    try {
      while (queuedAdditions.isNotEmpty || _pendingActivations.isNotEmpty) {
        if (_disposed ||
            requestGeneration != _requestGeneration ||
            !_sipAllowed) {
          return;
        }
        final elapsed = clock.elapsedMilliseconds;
        _pendingActivations.removeWhere(
          (_, started) => elapsed - started >= 2000,
        );
        // Sliding window: a slow/offline target must not block every healthy
        // target in its batch. Reserve both packages before issuing a target.
        final pendingExtensions = _pendingActivations.keys
            .map((key) => key.split('|').first)
            .toSet()
            .length;
        final capacity = 8 - pendingExtensions;
        if (capacity > 0 && queuedAdditions.isNotEmpty) {
          // Reconsider only unsent targets, so scrolling during initial load
          // can advance the viewport without resetting active subscriptions.
          final target = _prioritizedTargets(queuedAdditions).first;
          final visible = _visiblePriority.isEmpty
              ? _startupPriority.contains(target)
              : _visiblePriority.contains(target);
          final interval = _scrolling ? (visible ? 64 : 250) : 32;
          final wait = interval - (elapsed - lastStart);
          if (wait > 0) {
            await Future<void>.delayed(
              Duration(milliseconds: wait.clamp(1, 32)),
            );
            continue;
          }
          final batch = [target];
          for (final target in batch) {
            _pendingActivations['$target|dialog'] = elapsed;
            _pendingActivations['$target|presence'] = elapsed;
          }
          queuedAdditions.removeAll(batch);
          lastStart = elapsed;
          await reconcile(desired, batch, nativeGeneration);
          // Yield between native requests even if all callbacks are immediate.
          await Future<void>.delayed(Duration.zero);
          continue;
        }
        if (_pendingActivations.isEmpty) continue;
        final completer = Completer<void>();
        _activationCompleter = completer;
        final oldest = _pendingActivations.values.reduce(
          (a, b) => a < b ? a : b,
        );
        final timeout = Timer(
          Duration(
            milliseconds: (2000 - (clock.elapsedMilliseconds - oldest)).clamp(
              1,
              2000,
            ),
          ),
          () {
            if (!completer.isCompleted) completer.complete();
          },
        );
        try {
          await completer.future;
        } finally {
          timeout.cancel();
          if (identical(_activationCompleter, completer)) {
            _activationCompleter = null;
          }
        }
      }
    } finally {
      clock.stop();
      _pendingActivations.clear();
    }
  }

  Future<void> _restoreCache(String identityKey) async {
    final cache = this.cache;
    if (cache == null) return;
    try {
      final now = _now().toUtc();
      final snapshot = await cache.read(identityKey: identityKey, now: now);
      if (snapshot == null) return;
      for (final entry in snapshot.extensions.entries) {
        final dialog = entry.value.dialog;
        if (dialog != null) {
          final expiredRinging =
              dialog.presence == DirectoryPresence.ringing &&
              now.difference(dialog.observedAt) > cachedRingingLifetime;
          // Never turn an old ringing snapshot into apparent availability.
          // Wait for a fresh NOTIFY so the post-restart state is honest.
          if (expiredRinging) continue;
          _dialog[entry.key] = _PresenceObservation(
            presence: dialog.presence,
            observedAt: dialog.observedAt,
            fresh: false,
          );
        }
        final availability = entry.value.availability;
        if (availability != null) {
          _availability[entry.key] = _PresenceObservation(
            presence: availability.presence,
            observedAt: availability.observedAt,
            fresh: false,
          );
        }
      }
      _notifyChanged();
    } catch (_) {
      // BLF cache is an optimization and must never block registration.
    }
  }

  List<String> _prioritizedTargets(Set<String> targets) {
    final foreground = <String, int>{};
    for (final target in [..._visiblePriority, ..._startupPriority]) {
      foreground.putIfAbsent(target, () => foreground.length);
    }
    int priority(String target) {
      final states = [
        _dialog[target]?.presence,
        _availability[target]?.presence,
      ];
      if (states.contains(DirectoryPresence.ringing) ||
          states.contains(DirectoryPresence.busy)) {
        return 0;
      }
      if (states.contains(DirectoryPresence.available)) {
        return 1;
      }
      return 2;
    }

    final ordered = targets.toList();
    ordered.sort((left, right) {
      final leftVisible = foreground[left];
      final rightVisible = foreground[right];
      if (leftVisible != null || rightVisible != null) {
        if (leftVisible == null) return 1;
        if (rightVisible == null) return -1;
        return leftVisible.compareTo(rightVisible);
      }
      final comparison = priority(left).compareTo(priority(right));
      return comparison != 0 ? comparison : left.compareTo(right);
    });
    return ordered;
  }

  void _onEvent(Map<String, dynamic> event) {
    if (_disposed) return;
    final target = '${event['extension'] ?? ''}'.trim();
    if (!_targets.contains(target) || !_sipAllowed) return;
    final eventGeneration = switch (event['generation']) {
      int value => value,
      num value => value.toInt(),
      _ => 0,
    };
    if (eventGeneration != 0 && eventGeneration < _nativeGeneration) return;

    final package = '${event['event'] ?? 'dialog'}'.trim().toLowerCase();
    if (eventGeneration == _activationGeneration) {
      final kind = '${event['kind'] ?? 'notify'}'.toLowerCase();
      final state = '${event['state'] ?? ''}'.toLowerCase();
      if (kind == 'notify' ||
          state == 'active' ||
          state == 'error' ||
          state == 'terminated' ||
          state == 'retained') {
        final released = _pendingActivations.remove('$target|$package');
        if (released != null && _activationCompleter?.isCompleted == false) {
          _activationCompleter?.complete();
        }
      }
    }
    final states = package == 'presence' ? _availability : _dialog;
    if ('${event['kind'] ?? 'notify'}'.toLowerCase() == 'subscription') {
      final state = '${event['state'] ?? ''}'.toLowerCase();
      if (state == 'error' || state == 'terminated') {
        _failedTargets.add(target);
        AppLogger.warning(
          'BLF subscription awaiting retry',
          data: {
            'failures': _failedTargets.length,
            'generation': eventGeneration,
          },
        );
        _scheduleRetry();
        final previous = states[target];
        if (previous != null && previous.fresh) {
          states[target] = previous.asStale();
          _notifyChanged();
          _scheduleCacheWrite();
        }
      }
      return;
    }

    final update = parseSipPresenceEvent(event);
    if (update == null) return;
    _failedTargets.remove(target);
    if (_failedTargets.isEmpty) {
      _retryTimer?.cancel();
      _retryAttempt = 0;
    }
    final observedAt = _eventObservedAt(event) ?? _now().toUtc();
    final previous = states[target];
    if (_feedSourced.contains(target) &&
        previous != null &&
        previous.fresh &&
        previous.observedAt.isAfter(observedAt)) {
      return;
    }
    _recordAuthoritativeUpdate(target, package, eventGeneration);
    _feedSourced.remove(target);
    states[target] = _PresenceObservation(
      presence: update.presence,
      observedAt: observedAt,
      fresh: true,
    );
    _scheduleCacheWrite();
    if (previous?.presence != update.presence || previous?.fresh != true) {
      _notifyChanged();
    }
  }

  void _armFeedFallback() {
    if (_disposed ||
        _feedAuthoritative ||
        _sipFallback ||
        _feedFallbackTimer?.isActive == true ||
        feed?.status == BlfFeedStatus.paused) {
      return;
    }
    _feedFallbackTimer = Timer(feedFallbackDelay, _startSipFallback);
  }

  void _onFeedEvent(BlfFeedEvent event) {
    if (_disposed) return;
    switch (event) {
      case BlfFeedSnapshot():
        final becameAuthoritative = !_feedAuthoritative;
        _feedAuthoritative = true;
        _feedFallbackTimer?.cancel();
        if (_applyFeedStates(event.states, replace: true) ||
            becameAuthoritative) {
          _notifyChanged();
        }
        if (_sipFallback) _handBackToFeed();
      case BlfFeedDelta():
        if (_feedAuthoritative &&
            _applyFeedStates(event.states, replace: false)) {
          _notifyChanged();
        }
      case BlfFeedLost():
        _feedAuthoritative = false;
        if (_markFeedStale()) _notifyChanged();
        switch (event.reason) {
          case BlfFeedLossReason.retrying:
            _armFeedFallback();
          case BlfFeedLossReason.unavailable:
            _feedFallbackTimer?.cancel();
            _startSipFallback();
          case BlfFeedLossReason.paused:
            _feedFallbackTimer?.cancel();
        }
    }
  }

  /// Returns whether any rendered value changed; the caller notifies once. A
  /// snapshot replaces the view; a delta yields to a newer fresh observation.
  bool _applyFeedStates(
    Map<String, BlfFeedState> states, {
    required bool replace,
  }) {
    var changed = false;
    for (final entry in states.entries) {
      final target = entry.key;
      final state = entry.value;
      if (!_targets.contains(target)) continue;
      final observedAt = state.observedAt;
      if (observedAt == null && state.presence == DirectoryPresence.unknown) {
        continue;
      }
      final observation = _PresenceObservation(
        presence: state.presence,
        observedAt: observedAt ?? _now().toUtc(),
        fresh: state.fresh,
      );
      final previousDialog = _dialog[target];
      final previousAvailability = _availability[target];
      bool older(_PresenceObservation? previous) =>
          !replace &&
          previous != null &&
          previous.fresh &&
          previous.observedAt.isAfter(observation.observedAt);
      switch (state.presence) {
        case DirectoryPresence.busy || DirectoryPresence.ringing:
          if (older(previousDialog)) continue;
          _dialog[target] = observation;
        case DirectoryPresence.available:
          if (older(previousDialog) || older(previousAvailability)) continue;
          _dialog[target] = observation;
          _availability[target] = observation;
        case DirectoryPresence.unregistered:
          if (older(previousAvailability)) continue;
          _dialog.remove(target);
          _availability[target] = observation;
        case DirectoryPresence.unknown:
          _dialog.remove(target);
          _availability.remove(target);
      }
      _feedSourced.add(target);
      _failedTargets.remove(target);
      changed |=
          previousDialog?.presence != _dialog[target]?.presence ||
          previousDialog?.fresh != _dialog[target]?.fresh ||
          previousAvailability?.presence != _availability[target]?.presence ||
          previousAvailability?.fresh != _availability[target]?.fresh;
    }
    if (states.isNotEmpty) _scheduleCacheWrite();
    return changed;
  }

  bool _markFeedStale() {
    var changed = false;
    for (final target in _feedSourced) {
      for (final states in [_dialog, _availability]) {
        final value = states[target];
        if (value != null && value.fresh) {
          states[target] = value.asStale();
          changed = true;
        }
      }
    }
    if (changed) _scheduleCacheWrite();
    return changed;
  }

  void _startSipFallback() {
    if (_disposed || feed == null || _sipFallback) return;
    _sipFallback = true;
    AppLogger.warning('BLF feed unavailable; using SIP presence');
    _writes = _writes.catchError((_) {}).then((_) async {
      if (_disposed || !_registered || _identityKey == null || !_sipAllowed) {
        return;
      }
      final requestGeneration = _requestGeneration;
      final ordered = _prioritizedTargets(_targets);
      final nativeGeneration = ++_nativeGeneration;
      _beginConvergence(ordered);
      try {
        await _reconcileInBatches(
          ordered,
          nativeGeneration,
          requestGeneration,
          additions: ordered,
        );
      } catch (error, stackTrace) {
        _markAllStale();
        AppLogger.error(
          'BLF fallback reconciliation failed',
          error: error,
          stackTrace: stackTrace,
        );
      }
    });
  }

  /// The feed is authoritative again: SIP presence stops for its targets and
  /// the generation bump fences any native event still in flight.
  void _handBackToFeed() {
    _sipFallback = false;
    ++_nativeGeneration;
    _failedTargets.clear();
    _retryTimer?.cancel();
    _retryAttempt = 0;
    _pendingActivations.clear();
    if (_activationCompleter?.isCompleted == false) {
      _activationCompleter?.complete();
    }
    AppLogger.info('BLF feed recovered; stopping SIP presence');
    _writes = _writes.catchError((_) {}).then((_) async {
      if (_disposed || _sipFallback) return;
      try {
        await stop();
      } catch (_) {}
    });
  }

  void _scheduleRetry() {
    if (_disposed ||
        !_registered ||
        _failedTargets.isEmpty ||
        _retryTimer?.isActive == true) {
      return;
    }
    const delays = [2, 5, 15, 30, 60, 120, 300];
    final seconds = delays[_retryAttempt.clamp(0, delays.length - 1)];
    final jitterMs =
        _failedTargets
            .fold<int>(0, (sum, value) => sum + value.hashCode)
            .abs() %
        500;
    _retryTimer = Timer(Duration(seconds: seconds, milliseconds: jitterMs), () {
      // A retry must not replace the generation/window of an initial load.
      _writes = _writes.catchError((_) {}).then((_) => _retryFailedTargets());
    });
  }

  Future<void> _retryFailedTargets() async {
    if (_disposed ||
        !_registered ||
        _identityKey == null ||
        _failedTargets.isEmpty) {
      return;
    }
    final requestGeneration = _requestGeneration;
    final desired = _prioritizedTargets(_targets);
    final failed = desired
        .where(_failedTargets.contains)
        .toList(growable: false);
    if (failed.isEmpty) return;
    _retryAttempt += 1;
    final nativeGeneration = ++_nativeGeneration;
    _beginConvergence(failed);
    AppLogger.info(
      'BLF retry reconcile',
      data: {
        'desired': desired.length,
        'added': failed.length,
        'queueDepth': failed.length * 2,
        'failures': _failedTargets.length,
        'generation': nativeGeneration,
      },
    );
    try {
      await _reconcileInBatches(
        desired,
        nativeGeneration,
        requestGeneration,
        additions: failed,
      );
    } catch (_) {
      // The failed targets remain queued for the next bounded retry.
    }
    if (_failedTargets.isNotEmpty) _scheduleRetry();
  }

  DateTime? _eventObservedAt(Map<String, dynamic> event) {
    final raw = event['observedAt'];
    if (raw is int) {
      return DateTime.fromMillisecondsSinceEpoch(raw, isUtc: true);
    }
    if (raw is num) {
      return DateTime.fromMillisecondsSinceEpoch(raw.toInt(), isUtc: true);
    }
    return DateTime.tryParse('${raw ?? ''}')?.toUtc();
  }

  void _beginConvergence(Iterable<String> additions) {
    _convergenceStartedAt = _now().toUtc();
    _firstAuthoritativeLogged = false;
    _awaitingAuthoritative = {
      for (final target in additions) '$target|dialog',
      for (final target in additions) '$target|presence',
    };
    if (_awaitingAuthoritative.isEmpty) {
      AppLogger.info('BLF converged', data: {'elapsedMs': 0, 'targets': 0});
    }
  }

  void _recordAuthoritativeUpdate(
    String target,
    String package,
    int eventGeneration,
  ) {
    if (eventGeneration != _nativeGeneration ||
        !_awaitingAuthoritative.remove('$target|$package')) {
      return;
    }
    final startedAt = _convergenceStartedAt;
    if (startedAt == null) return;
    final elapsed = _now().toUtc().difference(startedAt).inMilliseconds;
    if (!_firstAuthoritativeLogged) {
      _firstAuthoritativeLogged = true;
      AppLogger.info(
        'BLF first authoritative update',
        data: {'elapsedMs': elapsed, 'generation': eventGeneration},
      );
    }
    if (_awaitingAuthoritative.isEmpty) {
      AppLogger.info(
        'BLF converged',
        data: {'elapsedMs': elapsed, 'generation': eventGeneration},
      );
    }
  }

  void _markAllStale() {
    var changed = false;
    // SIP registration loss says nothing about values the feed is delivering.
    bool keep(String target) =>
        _feedAuthoritative && _feedSourced.contains(target);
    for (final entry in _dialog.entries.toList()) {
      if (entry.value.fresh && !keep(entry.key)) {
        _dialog[entry.key] = entry.value.asStale();
        changed = true;
      }
    }
    for (final entry in _availability.entries.toList()) {
      if (entry.value.fresh && !keep(entry.key)) {
        _availability[entry.key] = entry.value.asStale();
        changed = true;
      }
    }
    if (changed) {
      _notifyChanged();
      _scheduleCacheWrite();
    }
  }

  List<DirectoryEntry> apply(Iterable<DirectoryEntry> entries) => [
    for (final entry in entries)
      if (!entry.isCompany) entry else _applyPresence(entry),
  ];

  DirectoryEntry _applyPresence(DirectoryEntry entry) {
    final dialog = entry.numbers
        .map((number) => _dialog[number.trim()])
        .whereType<_PresenceObservation>()
        .toList(growable: false);
    final availability = entry.numbers
        .map((number) => _availability[number.trim()])
        .whereType<_PresenceObservation>()
        .toList(growable: false);
    if (dialog.isEmpty && availability.isEmpty) return entry;

    final presence = directoryPresenceWithRegistration(
      entry: entry,
      liveStates: dialog.map((state) => state.presence),
      availabilityStates: availability.map((state) => state.presence),
    );
    final relevant = switch (presence) {
      DirectoryPresence.ringing => dialog.where(
        (state) => state.presence == DirectoryPresence.ringing,
      ),
      DirectoryPresence.busy => dialog.where(
        (state) => state.presence == DirectoryPresence.busy,
      ),
      DirectoryPresence.available => [
        ...dialog,
        ...availability,
      ].where((state) => state.presence == DirectoryPresence.available),
      DirectoryPresence.unregistered => availability.where(
        (state) => state.presence == DirectoryPresence.unregistered,
      ),
      DirectoryPresence.unknown => [...dialog, ...availability],
    }.toList(growable: false);
    final observedAt = relevant
        .map((state) => state.observedAt)
        .fold<DateTime?>(null, (latest, value) {
          if (latest == null || value.isAfter(latest)) return value;
          return latest;
        });
    final live =
        (_registered || _feedAuthoritative) &&
        relevant.any((state) => state.fresh);
    return entry.copyWith(
      presence: presence,
      presenceFreshness: live
          ? DirectoryPresenceFreshness.live
          : DirectoryPresenceFreshness.stale,
      presenceObservedAt: observedAt,
    );
  }

  void _scheduleCacheWrite() {
    if (_identityKey == null || cache == null || _disposed) return;
    _cacheWriteTimer?.cancel();
    _cacheWriteTimer = Timer(
      const Duration(milliseconds: 500),
      () => unawaited(_persistCache()),
    );
  }

  Future<void> _persistCache() async {
    final identityKey = _identityKey;
    final cache = this.cache;
    if (identityKey == null || cache == null) return;
    final extensions = <String, CachedExtensionPresence>{};
    for (final target in _targets) {
      final dialog = _dialog[target];
      final availability = _availability[target];
      if (dialog == null && availability == null) continue;
      extensions[target] = CachedExtensionPresence(
        dialog: dialog == null
            ? null
            : CachedPresenceValue(
                presence: dialog.presence,
                observedAt: dialog.observedAt,
              ),
        availability: availability == null
            ? null
            : CachedPresenceValue(
                presence: availability.presence,
                observedAt: availability.observedAt,
              ),
      );
    }
    try {
      await cache.write(
        DirectoryPresenceCacheSnapshot(
          identityKey: identityKey,
          savedAt: _now().toUtc(),
          extensions: extensions,
        ),
      );
    } catch (_) {
      // Presence remains fully functional if the optimization cannot persist.
    }
  }

  void _notifyChanged() {
    if (_disposed || _changes.isClosed || _changeTimer?.isActive == true) {
      return;
    }
    // State is updated immediately; only rendering notifications are batched.
    // A fixed window (not a debounce) cannot starve the UI during long bursts.
    _changeTimer = Timer(const Duration(milliseconds: 80), () {
      if (!_disposed && !_changes.isClosed) _changes.add(null);
    });
  }

  bool _sameTargets(Set<String> left, Set<String> right) =>
      left.length == right.length && left.containsAll(right);

  Future<void> dispose() async {
    _disposed = true;
    ++_requestGeneration;
    _cacheWriteTimer?.cancel();
    _changeTimer?.cancel();
    _retryTimer?.cancel();
    _scrollIdleTimer?.cancel();
    _feedFallbackTimer?.cancel();
    if (_activationCompleter?.isCompleted == false) {
      _activationCompleter?.complete();
    }
    await _persistCache();
    await _subscription.cancel();
    await _feedSubscription?.cancel();
    await _writes.catchError((_) {});
    try {
      await stop();
    } catch (_) {}
    // A hidden UI consumer can have a paused subscription. Native teardown
    // must not wait indefinitely for that consumer to drain its done event.
    unawaited(_changes.close());
  }
}
