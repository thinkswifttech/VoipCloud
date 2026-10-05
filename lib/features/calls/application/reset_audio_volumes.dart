import '../domain/audio_volume_levels.dart';

/// Uses the same persisted native setters as the sliders. Never changes the
/// OS-owned mobile call/ringtone volume. Mobile exposes only call waiting.
Future<void> resetAudioVolumes({
  required Future<void> Function(AudioVolumeKind kind, int level) save,
  required bool mobileControlsOnly,
}) async {
  for (final kind in AudioVolumeKind.values) {
    if (mobileControlsOnly && kind != AudioVolumeKind.callWaiting) {
      continue;
    }
    await save(kind, AudioVolumeLevels.defaults.levelFor(kind));
  }
}
