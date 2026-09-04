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
  }) : _channel = channel,
       _registrationEvents = registrationEvents,
       _callEvents = callEvents,
       _messageEvents = messageEvents,
       _sipLogEvents = sipLogEvents,
       _presenceEvents = presenceEvents;

  final MethodChannel _channel;
  final EventChannel _registrationEvents;
  final EventChannel _callEvents;
  final EventChannel _messageEvents;
  final EventChannel _sipLogEvents;
  final EventChannel _presenceEvents;

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
    return _presenceEvents.receiveBroadcastStream().map(_asMap);
  }

  Future<void> startPresenceSubscriptions(Iterable<String> extensions) {
    return _channel.invokeMethod<void>('startPresenceSubscriptions', {
      'extensions': extensions.toSet().toList(growable: false),
    });
  }

  Future<void> stopPresenceSubscriptions() {
    return _channel.invokeMethod<void>('stopPresenceSubscriptions');
  }

  Future<void> initialize() {
    return _channel.invokeMethod<void>('initialize');
  }

  Future<void> configureAccount(Map<String, Object?> account) {
    return _channel.invokeMethod<void>('configureAccount', account);
  }

  Future<void> register() {
    return _channel.invokeMethod<void>('register');
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

  /// Places a short SIP INVITE for a PBX feature code (e.g. *76). Returns the
  /// native call id so Flutter can suppress UI/history for that call.
  Future<String?> dialFeatureCode(String code) {
    return _channel.invokeMethod<String>('dialFeatureCode', {'code': code});
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

  Future<void> updateDirectoryCache({
    required String tenantKey,
    required List<Map<String, Object?>> entries,
  }) {
    return _channel.invokeMethod<void>('updateDirectoryCache', {
      'tenantKey': tenantKey,
      'entries': entries,
    });
  }

  Future<void> setNativeDnd(bool enabled) {
    return _channel.invokeMethod<void>('setNativeDnd', {'enabled': enabled});
  }

  Future<void> clearNativeCallState() {
    return _channel.invokeMethod<void>('clearNativeCallState');
  }

  Future<List<Map<String, dynamic>>> getAudioRoutes() async {
    final result = await _channel.invokeMethod<List<dynamic>>('getAudioRoutes');
    if (result == null) {
      return const [];
    }
    return result
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();
  }

  Future<String?> setAudioRoute(String route, {String? endpointId}) {
    return _channel.invokeMethod<String>('setAudioRoute', {
      'route': route,
      'endpointId': ?endpointId,
    });
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

  Future<void> transferCall({
    required String callId,
    required String destination,
  }) {
    return _channel.invokeMethod<void>('transferCall', {
      'callId': callId,
      'destination': destination,
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
