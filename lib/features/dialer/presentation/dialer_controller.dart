import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../session/presentation/session_controller.dart';

final dialerControllerProvider = NotifierProvider<DialerController, String>(
  DialerController.new,
);

class DialerController extends Notifier<String> {
  @override
  String build() => '';

  void append(String value) {
    replaceRange(state.length, state.length, value);
  }

  void setDestination(String value) {
    state = _dialCharacters(value);
  }

  /// Replaces `[start, end)` with dial characters from [value].
  /// Returns the cursor offset after the inserted text.
  int replaceRange(int start, int end, String value) {
    final dialChars = _dialCharacters(value);
    final from = start.clamp(0, state.length);
    final to = end.clamp(0, state.length);
    final low = from < to ? from : to;
    final high = from < to ? to : from;
    state = state.replaceRange(low, high, dialChars);
    return low + dialChars.length;
  }

  /// Deletes a selection, or [count] characters before a collapsed cursor.
  /// Returns the cursor offset after the deletion.
  int deleteBackward(int cursor, {int count = 1, int? selectionEnd}) {
    if (state.isEmpty) {
      return 0;
    }

    final end = (selectionEnd ?? cursor).clamp(0, state.length);
    final start = cursor.clamp(0, state.length);
    if (start != end) {
      final low = start < end ? start : end;
      final high = start < end ? end : start;
      state = state.replaceRange(low, high, '');
      return low;
    }

    if (start <= 0) {
      return 0;
    }
    final deleteFrom = (start - count).clamp(0, start);
    state = state.replaceRange(deleteFrom, start, '');
    return deleteFrom;
  }

  void backspace([int count = 1]) {
    deleteBackward(state.length, count: count);
  }

  void clear() {
    state = '';
  }

  Future<String?> call() async {
    final destination = state.trim();
    if (destination.isEmpty) {
      return null;
    }
    final service = ref.read(sipServiceProvider);
    await service.makeCall(destination);
    final callId = service.activeCall?.id;
    clear();
    return callId;
  }
}

String _dialCharacters(String value) {
  return value
      .split('')
      .where((char) => RegExp(r'[0-9*#+,;]').hasMatch(char))
      .join();
}
