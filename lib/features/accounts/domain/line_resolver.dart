import '../../call_history/domain/call_history_item.dart';
import 'account_models.dart';

enum LineReason { singleAccount, context, numberHistory, defaultSetting, ask }

/// The outcome of choosing the line for a new outgoing call. A null [line]
/// means the app has to ask.
class LineChoice {
  const LineChoice(this.line, this.reason);

  final AccountLine? line;
  final LineReason reason;

  bool get mustAsk => line == null;
}

/// How long a past call or message keeps deciding the line for that number.
const lineMemory = Duration(days: 60);

/// Chooses the line for a call, in this order:
/// 1. one account only: that account;
/// 2. [hint]: the line of the history entry, call or thread the user came from;
/// 3. the line last used with this number;
/// 4. the user's default line (if they set one);
/// 5. otherwise ask.
LineChoice resolveOutgoingLine({
  required bool hasSecondary,
  required String destination,
  required Iterable<CallHistoryItem> history,
  required DefaultOutgoingLine defaultOutgoing,
  AccountLine? hint,
  DateTime? now,
}) {
  if (!hasSecondary) {
    return const LineChoice(AccountLine.primary, LineReason.singleAccount);
  }
  if (hint != null) return LineChoice(hint, LineReason.context);
  final remembered = lineLastUsedWith(
    destination,
    history,
    now: now ?? DateTime.now(),
  );
  if (remembered != null) {
    return LineChoice(remembered, LineReason.numberHistory);
  }
  final configured = defaultOutgoing.line;
  if (configured != null) {
    return LineChoice(configured, LineReason.defaultSetting);
  }
  return const LineChoice(null, LineReason.ask);
}

/// The line of the most recent recent call with [number], if one is known.
AccountLine? lineLastUsedWith(
  String number,
  Iterable<CallHistoryItem> history, {
  required DateTime now,
}) {
  CallHistoryItem? best;
  for (final item in history) {
    final line = item.line;
    if (line == null) continue;
    if (now.difference(item.startedAt) > lineMemory) continue;
    if (!sameNumber(item.remoteNumber, number)) continue;
    if (best == null || item.startedAt.isAfter(best.startedAt)) best = item;
  }
  return best?.line;
}

/// Digits only; long numbers match on their last ten digits so `+1 416 ...`
/// and `416 ...` are the same person, short extensions must match exactly.
bool sameNumber(String a, String b) {
  final left = _digits(a);
  final right = _digits(b);
  if (left.isEmpty || right.isEmpty) return false;
  if (left.length < 7 || right.length < 7) return left == right;
  return _tail(left) == _tail(right);
}

String _digits(String value) {
  // Keep only the number itself: pauses (`,` and `;`) start dial-after digits.
  final end = value.indexOf(RegExp('[,;]'));
  final head = end < 0 ? value : value.substring(0, end);
  return head.replaceAll(RegExp(r'[^0-9]'), '');
}

String _tail(String digits) =>
    digits.length <= 10 ? digits : digits.substring(digits.length - 10);
