import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A message about a call that ended while the app was not on screen (for
/// example, its network was lost). It is shown once when the user returns.
final pendingCallNoticeProvider = NotifierProvider<PendingCallNotice, String?>(
  PendingCallNotice.new,
);

class PendingCallNotice extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String message) => state = message;

  void clear() => state = null;
}
