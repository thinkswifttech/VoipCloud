import 'call_direction.dart';
import 'call_status.dart';
import 'audio_output_route.dart';

class VoipCall {
  const VoipCall({
    required this.id,
    required this.remoteUri,
    required this.direction,
    required this.status,
    required this.startedAt,
    this.remoteDisplayName,
    this.endedAt,
    this.isMuted = false,
    this.isSpeakerEnabled = false,
    this.audioRoute = AudioOutputRoute.earpiece,
    this.audioEndpointId,
    this.availableAudioEndpoints = const [],
    this.answeredElsewhere = false,
  });

  final String id;
  final String remoteUri;
  final String? remoteDisplayName;
  final CallDirection direction;
  final CallStatus status;
  final DateTime startedAt;
  final DateTime? endedAt;
  final bool isMuted;
  final bool isSpeakerEnabled;
  final AudioOutputRoute audioRoute;
  final String? audioEndpointId;
  final List<AudioOutputRouteOption> availableAudioEndpoints;
  final bool answeredElsewhere;

  VoipCall copyWith({
    String? id,
    String? remoteUri,
    String? remoteDisplayName,
    CallDirection? direction,
    CallStatus? status,
    DateTime? startedAt,
    DateTime? endedAt,
    bool? isMuted,
    bool? isSpeakerEnabled,
    AudioOutputRoute? audioRoute,
    String? audioEndpointId,
    List<AudioOutputRouteOption>? availableAudioEndpoints,
    bool? answeredElsewhere,
  }) {
    return VoipCall(
      id: id ?? this.id,
      remoteUri: remoteUri ?? this.remoteUri,
      remoteDisplayName: remoteDisplayName ?? this.remoteDisplayName,
      direction: direction ?? this.direction,
      status: status ?? this.status,
      startedAt: startedAt ?? this.startedAt,
      endedAt: endedAt ?? this.endedAt,
      isMuted: isMuted ?? this.isMuted,
      isSpeakerEnabled: isSpeakerEnabled ?? this.isSpeakerEnabled,
      audioRoute: audioRoute ?? this.audioRoute,
      audioEndpointId: audioEndpointId ?? this.audioEndpointId,
      availableAudioEndpoints:
          availableAudioEndpoints ?? this.availableAudioEndpoints,
      answeredElsewhere: answeredElsewhere ?? this.answeredElsewhere,
    );
  }
}
