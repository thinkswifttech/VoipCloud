import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../accounts/domain/account_models.dart';
import '../../accounts/domain/line_resolver.dart';
import '../../accounts/presentation/accounts_controller.dart';
import '../../accounts/presentation/line_picker_sheet.dart';
import '../../call_history/presentation/call_history_providers.dart';
import 'dialer_controller.dart';

/// A line tied to one number: it only applies while that same number is
/// still in the dialer, so a stale choice never follows a different call.
class LineSelection {
  const LineSelection(this.destination, this.line);

  final String destination;
  final AccountLine line;
}

/// The line of the history entry, thread or call the user came from.
final dialerLineHintProvider =
    NotifierProvider<_LineSelectionNotifier, LineSelection?>(
      _LineSelectionNotifier.new,
    );

/// A line the user picked by hand for the number now in the dialer.
final dialerLineOverrideProvider =
    NotifierProvider<_LineSelectionNotifier, LineSelection?>(
      _LineSelectionNotifier.new,
    );

class _LineSelectionNotifier extends Notifier<LineSelection?> {
  @override
  LineSelection? build() => null;

  void set(String destination, AccountLine line) {
    state = LineSelection(normalizeDialDestination(destination), line);
  }

  void clear() => state = null;
}

AccountLine? _forNumber(LineSelection? selection, String destination) {
  if (selection == null) return null;
  return selection.destination == normalizeDialDestination(destination)
      ? selection.line
      : null;
}

/// The line the Call button would use right now (null: it will ask).
final dialerLineChoiceProvider = Provider<LineChoice>((ref) {
  final destination = ref.watch(dialerControllerProvider);
  final accounts = ref.watch(accountsControllerProvider).value;
  final history = ref.watch(callHistoryProvider).value ?? const [];
  final override = _forNumber(
    ref.watch(dialerLineOverrideProvider),
    destination,
  );
  final hint = _forNumber(ref.watch(dialerLineHintProvider), destination);
  return resolveOutgoingLine(
    hasSecondary: accounts?.hasSecondary ?? false,
    destination: destination,
    history: history,
    defaultOutgoing: accounts?.prefs.defaultOutgoing ?? DefaultOutgoingLine.ask,
    hint: override ?? hint,
  );
});

/// Settles which line to call from, asking when nothing decides. Returns null
/// when the user dismisses the question (no call should be placed).
Future<AccountLine?> chooseLineForCall(
  BuildContext context,
  WidgetRef ref,
) async {
  final choice = ref.read(dialerLineChoiceProvider);
  final line = choice.line;
  if (line != null) return line;

  final pick = await showLinePickerSheet(
    context,
    lines: ref.read(accountLinesProvider),
    destination: ref.read(dialerControllerProvider),
  );
  if (pick == null) return null;
  if (pick.remember) {
    await ref
        .read(accountsControllerProvider.notifier)
        .setDefaultOutgoing(
          pick.line == AccountLine.primary
              ? DefaultOutgoingLine.primary
              : DefaultOutgoingLine.secondary,
        );
  }
  return pick.line;
}
