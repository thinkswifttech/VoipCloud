List<Map<String, dynamic>> orderedMessagingEventsAfter(
  Object? value, {
  required int after,
}) {
  if (value is! List) return const [];
  final events = value
      .whereType<Map>()
      .map((item) => Map<String, dynamic>.from(item))
      .where((event) {
        final sequence = _sequence(event['sequence']);
        return sequence != null && sequence > after;
      })
      .toList(growable: false);
  events.sort(
    (left, right) =>
        _sequence(left['sequence'])!.compareTo(_sequence(right['sequence'])!),
  );
  return events;
}

int? _sequence(Object? value) =>
    value is num ? value.toInt() : int.tryParse('$value');
