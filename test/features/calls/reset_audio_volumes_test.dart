import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/features/calls/application/reset_audio_volumes.dart';
import 'package:phone_app/features/calls/domain/audio_volume_levels.dart';

void main() {
  test('restores all app volume defaults through persisted setters', () async {
    final saved = <AudioVolumeKind, int>{};
    await resetAudioVolumes(
      save: (kind, level) async => saved[kind] = level,
      mobileControlsOnly: false,
    );
    expect(saved, {
      AudioVolumeKind.microphone: 100,
      AudioVolumeKind.callAudio: 70,
      AudioVolumeKind.ringtone: 55,
      AudioVolumeKind.ringback: 45,
      AudioVolumeKind.callWaiting: 30,
    });
  });

  test('mobile reset changes only call waiting', () async {
    final saved = <AudioVolumeKind, int>{};
    await resetAudioVolumes(
      save: (kind, level) async => saved[kind] = level,
      mobileControlsOnly: true,
    );
    expect(saved, {AudioVolumeKind.callWaiting: 30});
  });

  test('reset waits for each native write before starting the next', () async {
    var saving = false;
    await resetAudioVolumes(
      save: (kind, level) async {
        expect(saving, false);
        saving = true;
        await Future<void>.delayed(Duration.zero);
        saving = false;
      },
      mobileControlsOnly: false,
    );
  });

  test(
    'native save failure is surfaced rather than reporting success',
    () async {
      await expectLater(
        resetAudioVolumes(
          save: (kind, level) async => throw StateError('native save failed'),
          mobileControlsOnly: false,
        ),
        throwsStateError,
      );
    },
  );
}
