class AudioVolumeLevels {
  const AudioVolumeLevels({
    required this.microphone,
    required this.callAudio,
    required this.ringtone,
    required this.ringback,
  });

  static const defaults = AudioVolumeLevels(
    microphone: 100,
    callAudio: 100,
    ringtone: 100,
    ringback: 100,
  );

  final int microphone;
  final int callAudio;
  final int ringtone;
  final int ringback;

  factory AudioVolumeLevels.fromPlatform(Map<String, dynamic> value) {
    int level(String key) {
      final raw = value[key];
      return raw is num ? raw.round().clamp(0, 100) : 100;
    }

    return AudioVolumeLevels(
      microphone: level('microphone'),
      callAudio: level('callAudio'),
      ringtone: level('ringtone'),
      ringback: level('ringback'),
    );
  }
}

enum AudioVolumeKind {
  microphone('microphone'),
  callAudio('callAudio'),
  ringtone('ringtone'),
  ringback('ringback');

  const AudioVolumeKind(this.platformValue);

  final String platformValue;
}
