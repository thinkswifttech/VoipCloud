import 'package:flutter/services.dart';

class VoipPlatformChannel {
  const VoipPlatformChannel({
    MethodChannel channel = const MethodChannel('voipcloud/linphone'),
    EventChannel registrationEvents = const EventChannel(
      'voipcloud/linphone/registration',
    ),
    EventChannel callEvents = const EventChannel('voipcloud/linphone/calls'),
    EventChannel messageEvents = const EventChannel(
      'voipcloud/linphone/messages',
    ),
    EventChannel sipLogEvents = const EventChannel('voipcloud/linphone/logs'),
    EventChannel presenceEvents = const EventChannel(
      'voipcloud/linphone/presence',
    ),
    EventChannel callingNetworkEvents = const EventChannel(
      'voipcloud/linphone/calling_network',
    ),
  }) : _channel = channel,
       _registrationEvents = registrationEvents,
       _callEvents = callEvents,
       _messageEvents = messageEvents,
       _sipLogEvents = sipLogEvents,
       _presenceEvents = presenceEvents,
       _callingNetworkEvents = callingNetworkEvents;

  final MethodChannel _channel;
  final EventChannel _registrationEvents;
  final EventChannel _callEvents;
  final EventChannel _messageEvents;
  final EventChannel _sipLogEvents;
  final EventChannel _presenceEvents;
  final EventChannel _callingNetworkEvents;

  // Directory and diagnostics must share one native event-channel listener.
  static final _presenceStreams = Expando<Stream<Map<String, dynamic>>>();

  Stream<Map<String, dynamic>> registrationEvents() {
    return _registrationEvents.receiveBroadcastStream().map(_asMap);
  }

  Stream<Map<String, dynamic>> callEvents() {
    return _callEvents.receiveBroadcastStream().map(_asMap);
  }

  Stream<Map<String, dynamic>> messageEvents() {
    return _messageEvents.receiveBroadcastStream().map(_asMap);
  }

  Stream<Map<String, dynamic>> sipLogEvents() {
    return _sipLogEvents.receiveBroadcastStream().map(_asMap);
  }

  Stream<Map<String, dynamic>> presenceEvents() {
    return _presenceStreams[this] ??= _presenceEvents
        .receiveBroadcastStream()
        .map(_asMap);
  }

  Future<void> startDndDiagnostic(String extension) {
    if (!RegExp(r'^[0-9]{2,8}$').hasMatch(extension)) {
      throw ArgumentError('A numeric extension is required.');
    }
    return _channel.invokeMethod<void>('startPresenceSubscriptions', {
      'extensions': ['*76$extension'],
      'diagnostic': true,
    });
  }

  Future<void> stopDndDiagnostic({String accountId = 'primary'}) =>
      _channel.invokeMethod<void>('stopPresenceSubscriptions', {
        'diagnostic': true,
        'accountId': accountId,
      });

  Future<void> reconcilePresenceSubscriptions(
    Iterable<String> extensions, {
    Iterable<String>? additions,
    required int generation,
  }) {
    return _channel.invokeMethod<void>('startPresenceSubscriptions', {
      'extensions': extensions.toSet().toList(growable: false),
      'additions': (additions ?? extensions).toSet().toList(growable: false),
      'generation': generation,
    });
  }

  Future<void> setPresenceTargets(Iterable<String> targets, int generation) =>
      _channel.invokeMethod<void>('setPresenceTargets', {
        'extensions': targets.toSet().toList(growable: false),
        'generation': generation,
      });

  Future<void> enqueuePresenceTargets(
    Iterable<String> targets,
    int generation,
  ) => _channel.invokeMethod<void>('enqueuePresenceTargets', {
    'additions': targets.toSet().toList(growable: false),
    'generation': generation,
  });

  @Deprecated('Use reconcilePresenceSubscriptions with an explicit generation')
  Future<void> startPresenceSubscriptions(Iterable<String> extensions) =>
      reconcilePresenceSubscriptions(extensions, generation: 0);

  Future<void> startPbxDndSubscription(
    String extension,
    String subscriptionId, {
    String accountId = 'primary',
  }) {
    if (!RegExp(r'^[0-9]{2,8}$').hasMatch(extension) ||
        subscriptionId.isEmpty) {
      throw ArgumentError(
        'A numeric extension and subscription epoch are required.',
      );
    }
    return _channel.invokeMethod<void>('startPresenceSubscriptions', {
      'extensions': ['*76$extension'],
      'diagnostic': true,
      'subscriptionId': subscriptionId,
      'accountId': accountId,
    });
  }

  Future<void> stopPresenceSubscriptions() {
    return _channel.invokeMethod<void>('stopPresenceSubscriptions');
  }

  Future<void> initialize() {
    return _channel.invokeMethod<void>('initialize');
  }

  /// Returns the UUID advertised in this installation's SIP `+sip.instance`.
  Future<String?> getSipInstanceId() async {
    final value = await _channel.invokeMethod<String>('getSipInstanceId');
    final normalized = value?.trim() ?? '';
    return normalized.isEmpty ? null : normalized;
  }

  Future<void> configureAccount(Map<String, Object?> account) {
    return _channel.invokeMethod<void>('configureAccount', account);
  }

  Future<void> register() {
    return _channel.invokeMethod<void>('register');
  }

  /// Adds (or replaces) the second SIP account next to the primary one. The
  /// primary account is not touched.
  Future<void> configureSecondaryAccount(Map<String, Object?> account) {
    return _channel.invokeMethod<void>('configureAccount', {
      ...account,
      'accountSlot': 'secondary',
    });
  }

  /// Removes only the second SIP account (and its saved credentials).
  Future<void> removeSecondaryAccount() {
    return _channel.invokeMethod<void>('removeSecondaryAccount');
  }

  Future<Map<String, dynamic>?> syncCurrentCall() async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'syncCurrentCall',
    );
    return result == null ? null : Map<String, dynamic>.from(result);
  }

  Future<bool> hasActiveCall() async {
    final result = await _channel.invokeMethod<bool>('hasActiveCall');
    return result ?? false;
  }

  Future<void> enterBackground() {
    return _channel.invokeMethod<void>('enterBackground');
  }

  Future<void> enterForeground() {
    return _channel.invokeMethod<void>('enterForeground');
  }

  Future<void> unregister() {
    return _channel.invokeMethod<void>('unregister');
  }

  /// Permanently removes native SIP accounts and authentication material after
  /// an unregister transaction has had a chance to reach the registrar.
  Future<void> purgeAccount() {
    return _channel.invokeMethod<void>('purgeAccount');
  }

  Future<void> makeCall(String destination) {
    return _channel.invokeMethod<void>('makeCall', {
      'destination': destination,
    });
  }

  /// Places a call from the account named by [accountId] (`secondary`).
  Future<void> makeCallOnAccount(String destination, String accountId) {
    return _channel.invokeMethod<void>('makeCall', {
      'destination': destination,
      'accountId': accountId,
    });
  }

  /// Places a short SIP INVITE for a PBX feature code (e.g. *76). Returns the
  /// native call id so Flutter can suppress UI/history for that call.
  Future<String?> dialFeatureCode(String code, {String? accountId}) {
    return _channel.invokeMethod<String>('dialFeatureCode', {
      'code': code,
      'accountId': ?accountId,
    });
  }

  Future<void> endCall(String callId) {
    return _channel.invokeMethod<void>('endCall', {'callId': callId});
  }

  Future<void> acceptCall(String callId) {
    return _channel.invokeMethod<void>('acceptCall', {'callId': callId});
  }

  Future<void> rejectCall(String callId) {
    return _channel.invokeMethod<void>('rejectCall', {'callId': callId});
  }

  Future<void> mute(bool enabled) {
    return _channel.invokeMethod<void>('mute', {'enabled': enabled});
  }

  Future<void> hold(String callId) {
    return _channel.invokeMethod<void>('hold', {'callId': callId});
  }

  Future<void> resume(String callId) {
    return _channel.invokeMethod<void>('resume', {'callId': callId});
  }

  Future<void> setSpeaker(bool enabled) {
    return _channel.invokeMethod<void>('setSpeaker', {'enabled': enabled});
  }

  Future<void> setBluetooth(bool enabled) {
    return _channel.invokeMethod<void>('setBluetooth', {'enabled': enabled});
  }

  Future<bool> ensureBluetoothPermission() async {
    final result = await _channel.invokeMethod<bool>(
      'ensureBluetoothPermission',
    );
    return result ?? false;
  }

  Future<bool> isBatteryOptimizationIgnored() async {
    final result = await _channel.invokeMethod<bool>(
      'isBatteryOptimizationIgnored',
    );
    return result ?? true;
  }

  /// Both Android background switches: the Doze exemption and the app's own
  /// background-usage restriction. See [AndroidBackgroundStatus].
  Future<AndroidBackgroundStatus> getBackgroundStatus() async {
    final result = await _channel.invokeMapMethod<String, Object?>(
      'getBackgroundStatus',
    );
    if (result == null) return const AndroidBackgroundStatus();
    return AndroidBackgroundStatus(
      exempt: result['exempt'] != false,
      restricted: result['restricted'] == true,
      standbyBucket: (result['standbyBucket'] as num?)?.toInt() ?? 10,
    );
  }

  /// The app's own system settings page (Battery / Background usage).
  Future<void> openAppBatterySettings() {
    return _channel.invokeMethod<void>('openAppBatterySettings');
  }

  Future<bool> requestIgnoreBatteryOptimizations() async {
    final result = await _channel.invokeMethod<bool>(
      'requestIgnoreBatteryOptimizations',
    );
    return result ?? false;
  }

  Future<void> openBatteryOptimizationSettings() {
    return _channel.invokeMethod<void>('openBatteryOptimizationSettings');
  }

  Future<bool> canUseFullScreenIntent() async {
    final result = await _channel.invokeMethod<bool>('canUseFullScreenIntent');
    return result ?? true;
  }

  Future<bool> requestFullScreenIntentPermission() async {
    final result = await _channel.invokeMethod<bool>(
      'requestFullScreenIntentPermission',
    );
    return result ?? false;
  }

  /// [line] is `primary` (default) or `secondary`: each account keeps its own
  /// cached names, so the same extension on two phone systems never mixes.
  Future<void> updateDirectoryCache({
    required String tenantKey,
    required List<Map<String, Object?>> entries,
    String line = 'primary',
  }) {
    return _channel.invokeMethod<void>('updateDirectoryCache', {
      'tenantKey': tenantKey,
      'entries': entries,
      'line': line,
    });
  }

  Future<void> setNativeDnd(bool enabled) {
    return _channel.invokeMethod<void>('setNativeDnd', {'enabled': enabled});
  }

  /// Mirrors the calling-network preference into native storage and applies
  /// it. [preference] is `auto`, `wifi` or `cellular`.
  Future<void> setCallingNetworkPreference({
    required bool enabled,
    required String preference,
  }) {
    return _channel.invokeMethod<void>('setCallingNetworkPreference', {
      'enabled': enabled,
      'preference': preference,
    });
  }

  /// Native routing status: requested/effective path, reason and whether a
  /// change is waiting for the current call to end. Empty when unsupported.
  Future<Map<String, Object?>> getCallingNetworkStatus() async {
    final result = await _channel.invokeMapMethod<String, Object?>(
      'getCallingNetworkStatus',
    );
    return result ?? const {};
  }

  /// Pushes the routing status whenever it changes (and once on listen).
  Stream<Map<String, Object?>> callingNetworkStatusEvents() {
    return _callingNetworkEvents.receiveBroadcastStream().map(
      (event) => Map<String, Object?>.from(event as Map),
    );
  }

  Future<void> clearNativeCallState() {
    return _channel.invokeMethod<void>('clearNativeCallState');
  }

  /// Removes a native terminal-call outbox item only after Dart has durably
  /// committed it to local call history.
  Future<void> acknowledgeCallHistoryEvent(String eventId) {
    return _channel.invokeMethod<void>('ackCallHistoryEvent', {
      'eventId': eventId,
    });
  }

  Future<void> setAppBadgeCount(
    int count, {
    int? missedCalls,
    int? unreadMessages,
  }) {
    return _channel.invokeMethod<void>('setAppBadgeCount', {
      'count': count < 0 ? 0 : count,
      if (missedCalls != null) 'missedCalls': missedCalls < 0 ? 0 : missedCalls,
      if (unreadMessages != null)
        'unreadMessages': unreadMessages < 0 ? 0 : unreadMessages,
    });
  }

  Future<List<Map<String, dynamic>>> getAudioRoutes() async {
    final result = await _channel.invokeMethod<dynamic>('getAudioRoutes');
    if (result is! Iterable) return const [];

    // StandardMethodCodec decodes native maps as Map<Object?, Object?>. Do not
    // cast the whole payload to Map<String, dynamic>: a single unexpected key
    // or stale native entry would otherwise reject every valid audio device.
    final routes = <Map<String, dynamic>>[];
    for (final item in result) {
      if (item is! Map) continue;
      final route = <String, dynamic>{};
      for (final entry in item.entries) {
        final key = entry.key;
        if (key is String) route[key] = entry.value;
      }
      if (route.isNotEmpty) routes.add(route);
    }
    return routes;
  }

  Future<String?> setAudioRoute(String route, {String? endpointId}) {
    return _channel.invokeMethod<String>('setAudioRoute', {
      'route': route,
      'endpointId': ?endpointId,
    });
  }

  Future<String?> setAudioInputDevice(String endpointId) {
    return _channel.invokeMethod<String>('setAudioInputDevice', {
      'endpointId': endpointId,
    });
  }

  Future<Map<String, dynamic>> getAudioVolumeLevels() async {
    final result = await _channel.invokeMethod<dynamic>('getAudioVolumeLevels');
    if (result is! Map) return const {};
    return {
      for (final entry in result.entries)
        if (entry.key is String) entry.key as String: entry.value,
    };
  }

  Future<void> setAudioVolume(String kind, int level) {
    return _channel.invokeMethod<void>('setAudioVolume', {
      'kind': kind,
      'level': level.clamp(0, 100),
    });
  }

  Future<void> playAudioTestSound() {
    return _channel.invokeMethod<void>('playAudioTestSound');
  }

  Future<void> previewCallWaitingAlert(int level) {
    return _channel.invokeMethod<void>('previewCallWaitingAlert', {
      'level': level.clamp(0, 100),
    });
  }

  Future<void> startAudioInputTest() {
    return _channel.invokeMethod<void>('startAudioInputTest');
  }

  Future<double> getAudioInputLevel() async {
    final value = await _channel.invokeMethod<num>('getAudioInputLevel');
    return (value?.toDouble() ?? 0).clamp(0, 1);
  }

  Future<void> stopAudioInputTest() {
    return _channel.invokeMethod<void>('stopAudioInputTest');
  }

  Future<void> sendDtmf(String value) {
    return _channel.invokeMethod<void>('sendDtmf', {'value': value});
  }

  Future<Map<String, dynamic>> getCallQuality({String? callId}) async {
    final result = await _channel.invokeMethod<dynamic>('getCallQuality', {
      'callId': callId,
    });
    if (result is Map) {
      return Map<String, dynamic>.from(result);
    }
    return const {};
  }

  Future<void> completeAttendedTransfer({
    required String originalCallId,
    required String consultationCallId,
  }) {
    return _channel.invokeMethod<void>('completeAttendedTransfer', {
      'originalCallId': originalCallId,
      'consultationCallId': consultationCallId,
    });
  }

  Future<void> mergeCalls({
    required String activeCallId,
    required String heldCallId,
  }) {
    return _channel.invokeMethod<void>('mergeCalls', {
      'activeCallId': activeCallId,
      'heldCallId': heldCallId,
    });
  }

  Future<void> sendMessage({
    required String destination,
    required String text,
  }) {
    return _channel.invokeMethod<void>('sendMessage', {
      'destination': destination,
      'text': text,
    });
  }

  Future<void> setSipLoggingEnabled(bool enabled) {
    return _channel.invokeMethod<void>('setSipLoggingEnabled', {
      'enabled': enabled,
    });
  }

  Future<void> appendSipLogLine(String line) {
    return _channel.invokeMethod<void>('appendSipLogLine', {'line': line});
  }

  Future<String> readSipLogFile() async {
    final result = await _channel.invokeMethod<String>('readSipLogFile');
    return result ?? '';
  }

  Future<void> clearSipLogFile() {
    return _channel.invokeMethod<void>('clearSipLogFile');
  }

  Future<void> dispose() {
    return _channel.invokeMethod<void>('dispose');
  }
}

Map<String, dynamic> _asMap(Object? value) {
  if (value is Map) {
    return Map<String, dynamic>.from(value);
  }
  return const {};
}

/// What Android allows the app to do in the background.
class AndroidBackgroundStatus {
  const AndroidBackgroundStatus({
    this.exempt = true,
    this.restricted = false,
    this.standbyBucket = 10,
  });

  /// Not subject to battery optimisation (Doze).
  final bool exempt;

  /// The user (or the phone) chose "Restricted" for the app's background usage.
  final bool restricted;

  /// Android's standby bucket: 10 active ... 40 rare, 45 restricted.
  final int standbyBucket;

  /// Restricted apps cannot run in the background, whatever Doze says.
  bool get isRestricted => restricted || standbyBucket >= 45;

  bool get isAllowed => exempt && !isRestricted;
}
