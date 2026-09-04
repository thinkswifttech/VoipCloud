class CallQualityInfo {
  const CallQualityInfo({
    required this.callId,
    required this.capturedAt,
    this.currentQuality,
    this.averageQuality,
    this.roundTripMs,
    this.jitterBufferMs,
    this.receiverLossPercent,
    this.senderLossPercent,
    this.localLossPercent,
    this.downloadKbps,
    this.uploadKbps,
    this.codec,
    this.durationSeconds,
    this.audioRoute,
    this.remoteUri,
  });

  /// MOS scores are always on a 1–5 scale.
  static const double maxQuality = 5;

  factory CallQualityInfo.fromMap(Map<String, dynamic> map) {
    return CallQualityInfo(
      callId: _string(map['callId']),
      capturedAt:
          DateTime.tryParse(_string(map['capturedAt'])) ?? DateTime.now(),
      currentQuality: _double(map['currentQuality']),
      averageQuality: _double(map['averageQuality']),
      roundTripMs: _double(map['roundTripMs']),
      jitterBufferMs: _double(map['jitterBufferMs']),
      receiverLossPercent: _double(map['receiverLossPercent']),
      senderLossPercent: _double(map['senderLossPercent']),
      localLossPercent: _double(map['localLossPercent']),
      downloadKbps: _double(map['downloadKbps']),
      uploadKbps: _double(map['uploadKbps']),
      codec: _nullableString(map['codec']),
      durationSeconds: _int(map['durationSeconds']),
      audioRoute: _nullableString(map['audioRoute']),
      remoteUri: _nullableString(map['remoteUri']),
    );
  }

  final String callId;
  final DateTime capturedAt;
  final double? currentQuality;
  final double? averageQuality;
  final double? roundTripMs;
  final double? jitterBufferMs;
  final double? receiverLossPercent;
  final double? senderLossPercent;
  final double? localLossPercent;
  final double? downloadKbps;
  final double? uploadKbps;
  final String? codec;
  final int? durationSeconds;
  final String? audioRoute;
  final String? remoteUri;

  String get qualityLabel {
    final score = currentQuality;
    if (score == null || score < 0) {
      return 'Unavailable';
    }
    if (score >= 4) return 'Good';
    if (score >= 3) return 'Fair';
    if (score >= 2) return 'Poor';
    if (score >= 1) return 'Very poor';
    return 'Unusable';
  }

  String formatScore(double? value) {
    if (value == null || value < 0) return '—';
    return '${value.toStringAsFixed(1)}/${maxQuality.toStringAsFixed(0)}';
  }

  /// Plain-text snapshot for support tickets / paste into chat.
  String toSupportText() {
    String fmt(double? value, {String suffix = '', int digits = 1}) {
      if (value == null || value < 0) return '—';
      return '${value.toStringAsFixed(digits)}$suffix';
    }

    String duration() {
      final seconds = durationSeconds;
      if (seconds == null || seconds < 0) return '—';
      final mins = seconds ~/ 60;
      final secs = (seconds % 60).toString().padLeft(2, '0');
      return '$mins:$secs';
    }

    return [
      'VoipCloud call quality',
      'Captured: ${capturedAt.toUtc().toIso8601String()}',
      'Call ID: ${callId.isEmpty ? '—' : callId}',
      'Quality: $qualityLabel (${formatScore(currentQuality)} MOS)',
      'MOS avg: ${formatScore(averageQuality)}',
      'RTT: ${fmt(roundTripMs, suffix: ' ms', digits: 0)}',
      'Jitter buffer: ${fmt(jitterBufferMs, suffix: ' ms', digits: 0)}',
      'Loss recv/send/local: ${fmt(receiverLossPercent, suffix: '%')} / ${fmt(senderLossPercent, suffix: '%')} / ${fmt(localLossPercent, suffix: '%')}',
      'Bitrate down/up: ${fmt(downloadKbps, suffix: ' kbps', digits: 0)} / ${fmt(uploadKbps, suffix: ' kbps', digits: 0)}',
      'Codec: ${codec?.trim().isNotEmpty == true ? codec!.trim() : '—'}',
      'Audio route: ${audioRoute?.trim().isNotEmpty == true ? audioRoute!.trim() : '—'}',
      'Duration: ${duration()}',
      if (remoteUri != null && remoteUri!.trim().isNotEmpty)
        'Remote: ${remoteUri!.trim()}',
    ].join('\n');
  }
}

String _string(Object? value, {String fallback = ''}) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? fallback : text;
}

String? _nullableString(Object? value) {
  final text = _string(value);
  return text.isEmpty ? null : text;
}

double? _double(Object? value) {
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse(value?.toString() ?? '');
}

int? _int(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value?.toString() ?? '');
}
