int estimatedCallDurationSeconds({
  required int? sampledSeconds,
  required DateTime? sampledAt,
  required DateTime now,
}) {
  if (sampledSeconds == null || sampledSeconds < 0 || sampledAt == null) {
    return 0;
  }
  final elapsedSinceSample = now
      .difference(sampledAt)
      .inSeconds
      .clamp(0, 86400);
  return sampledSeconds + elapsedSinceSample;
}

String formatCallDuration(int totalSeconds) {
  final safeSeconds = totalSeconds.clamp(0, 99 * 3600);
  final hours = safeSeconds ~/ 3600;
  final minutes = (safeSeconds % 3600) ~/ 60;
  final seconds = safeSeconds % 60;
  final paddedMinutes = minutes.toString().padLeft(2, '0');
  final paddedSeconds = seconds.toString().padLeft(2, '0');
  if (hours > 0) {
    return '$hours:$paddedMinutes:$paddedSeconds';
  }
  return '$paddedMinutes:$paddedSeconds';
}
