enum AudioOutputRoute {
  earpiece,
  speaker,
  bluetooth,
  wired,
  streaming;

  static AudioOutputRoute? tryParse(String? value) {
    return switch (value) {
      'earpiece' => AudioOutputRoute.earpiece,
      'speaker' => AudioOutputRoute.speaker,
      'bluetooth' => AudioOutputRoute.bluetooth,
      'wired' => AudioOutputRoute.wired,
      'streaming' => AudioOutputRoute.streaming,
      _ => null,
    };
  }

  String get channelValue => name;

  String get defaultLabel => switch (this) {
    AudioOutputRoute.earpiece => 'Audio',
    AudioOutputRoute.speaker => 'Speaker',
    AudioOutputRoute.bluetooth => 'Bluetooth',
    AudioOutputRoute.wired => 'Wired headset',
    AudioOutputRoute.streaming => 'External device',
  };
}

class AudioOutputRouteOption {
  const AudioOutputRouteOption({
    required this.route,
    required this.label,
    this.available = true,
    this.endpointId,
    this.selected = false,
  });

  final AudioOutputRoute route;
  final String label;
  final bool available;
  final String? endpointId;
  final bool selected;

  factory AudioOutputRouteOption.fromPlatform(Map<String, dynamic> event) {
    final route =
        AudioOutputRoute.tryParse('${event['route']}') ??
        AudioOutputRoute.earpiece;
    final label = '${event['label'] ?? ''}'.trim();
    return AudioOutputRouteOption(
      route: route,
      label: label.isEmpty ? route.defaultLabel : label,
      available: event['available'] != false,
      endpointId: '${event['id'] ?? ''}'.trim().isEmpty
          ? null
          : '${event['id']}'.trim(),
      selected: event['selected'] == true,
    );
  }
}
