class AudioVolumeLevels {
  const AudioVolumeLevels({
    required this.microphone,
    required this.callAudio,
    required this.ringtone,
    required this.ringback,
    required this.callWaiting,
  });

  /// Conservative app-local defaults. Microphone gain stays neutral while
  /// sounds delivered directly to an earpiece/headset start attenuated.
  static const defaults = AudioVolumeLevels(
    microphone: 100,
    callAudio: 70,
    ringtone: 55,
    ringback: 45,
    callWaiting: 30,
  );

  final int microphone;
  final int callAudio;
  final int ringtone;
  final int ringback;
  final int callWaiting;

  int levelFor(AudioVolumeKind kind) => switch (kind) {
    AudioVolumeKind.microphone => microphone,
    AudioVolumeKind.callAudio => callAudio,
    AudioVolumeKind.ringtone => ringtone,
    AudioVolumeKind.ringback => ringback,
    AudioVolumeKind.callWaiting => callWaiting,
  };

  AudioVolumeLevels copyWith({
    int? microphone,
    int? callAudio,
    int? ringtone,
    int? ringback,
    int? callWaiting,
  }) => AudioVolumeLevels(
    microphone: microphone ?? this.microphone,
    callAudio: callAudio ?? this.callAudio,
    ringtone: ringtone ?? this.ringtone,
    ringback: ringback ?? this.ringback,
    callWaiting: callWaiting ?? this.callWaiting,
  );

  factory AudioVolumeLevels.fromPlatform(Map<String, dynamic> value) {
    int level(String key) {
      final raw = value[key];
      final fallback = switch (key) {
        'microphone' => defaults.microphone,
        'callAudio' => defaults.callAudio,
        'ringtone' => defaults.ringtone,
        'ringback' => defaults.ringback,
        'callWaiting' => defaults.callWaiting,
        _ => 0,
      };
      return raw is num ? raw.round().clamp(0, 100) : fallback;
    }

    return AudioVolumeLevels(
      microphone: level('microphone'),
      callAudio: level('callAudio'),
      ringtone: level('ringtone'),
      ringback: level('ringback'),
      callWaiting: level('callWaiting'),
    );
  }
}

enum AudioVolumeKind {
  microphone('microphone'),
  callAudio('callAudio'),
  ringtone('ringtone'),
  ringback('ringback'),
  callWaiting('callWaiting');

  const AudioVolumeKind(this.platformValue);

  final String platformValue;
}
