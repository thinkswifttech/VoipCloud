import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/features/calls/presentation/call_duration.dart';

void main() {
  test('formats connected-call durations below one hour', () {
    expect(formatCallDuration(0), '00:00');
    expect(formatCallDuration(65), '01:05');
  });

  test('formats connected-call durations with hours', () {
    expect(formatCallDuration(3661), '1:01:01');
  });

  test('interpolates forward from the latest native duration sample', () {
    final sampledAt = DateTime.utc(2026, 9, 29, 12);
    expect(
      estimatedCallDurationSeconds(
        sampledSeconds: 42,
        sampledAt: sampledAt,
        now: sampledAt.add(const Duration(seconds: 3)),
      ),
      45,
    );
  });

  test('does not count time before the first native connected sample', () {
    expect(
      estimatedCallDurationSeconds(
        sampledSeconds: null,
        sampledAt: null,
        now: DateTime.utc(2026, 9, 29, 12),
      ),
      0,
    );
  });
}
