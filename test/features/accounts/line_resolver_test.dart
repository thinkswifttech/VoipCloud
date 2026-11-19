import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/features/accounts/domain/account_models.dart';
import 'package:phone_app/features/accounts/domain/line_resolver.dart';
import 'package:phone_app/features/call_history/domain/call_history_item.dart';
import 'package:phone_app/features/calls/domain/call_direction.dart';
import 'package:phone_app/features/calls/domain/call_status.dart';

final _now = DateTime(2026, 10, 29, 12);

CallHistoryItem _call(
  String number,
  AccountLine? line, {
  Duration ago = const Duration(days: 1),
}) => CallHistoryItem(
  id: 'c-$number-${ago.inHours}',
  remoteNumber: number,
  direction: CallDirection.outgoing,
  status: CallStatus.ended,
  startedAt: _now.subtract(ago),
  line: line,
);

LineChoice _resolve({
  bool hasSecondary = true,
  String destination = '4165550100',
  List<CallHistoryItem> history = const [],
  DefaultOutgoingLine defaultOutgoing = DefaultOutgoingLine.ask,
  AccountLine? hint,
}) => resolveOutgoingLine(
  hasSecondary: hasSecondary,
  destination: destination,
  history: history,
  defaultOutgoing: defaultOutgoing,
  hint: hint,
  now: _now,
);

void main() {
  test('with one account nothing is ever asked', () {
    final choice = _resolve(
      hasSecondary: false,
      hint: AccountLine.secondary,
      defaultOutgoing: DefaultOutgoingLine.secondary,
    );
    expect(choice.line, AccountLine.primary);
    expect(choice.reason, LineReason.singleAccount);
  });

  test('the line you came from beats everything else', () {
    final choice = _resolve(
      hint: AccountLine.secondary,
      history: [_call('4165550100', AccountLine.primary)],
      defaultOutgoing: DefaultOutgoingLine.primary,
    );
    expect(choice.line, AccountLine.secondary);
    expect(choice.reason, LineReason.context);
  });

  test('a number called before uses the line it was called on', () {
    final choice = _resolve(
      history: [
        _call('+1 (416) 555-0100', AccountLine.secondary),
        _call('4165550100', AccountLine.primary, ago: const Duration(days: 5)),
      ],
      defaultOutgoing: DefaultOutgoingLine.primary,
    );
    expect(choice.line, AccountLine.secondary);
    expect(choice.reason, LineReason.numberHistory);
  });

  test('the most recent call decides, and old or unknown ones do not', () {
    expect(
      _resolve(
        history: [
          _call(
            '4165550100',
            AccountLine.primary,
            ago: const Duration(days: 9),
          ),
          _call(
            '4165550100',
            AccountLine.secondary,
            ago: const Duration(days: 2),
          ),
        ],
      ).line,
      AccountLine.secondary,
    );
    // Older than the memory window, or from before there were two lines.
    final choice = _resolve(
      history: [
        _call(
          '4165550100',
          AccountLine.secondary,
          ago: const Duration(days: 90),
        ),
        _call('4165550100', null),
      ],
    );
    expect(choice.mustAsk, isTrue);
  });

  test('a configured default is used when nothing else decides', () {
    final choice = _resolve(defaultOutgoing: DefaultOutgoingLine.secondary);
    expect(choice.line, AccountLine.secondary);
    expect(choice.reason, LineReason.defaultSetting);
  });

  test('with no default and no history the app asks', () {
    expect(_resolve().mustAsk, isTrue);
  });

  test('short extensions match exactly, pauses are ignored', () {
    expect(sameNumber('210', '210'), isTrue);
    expect(sameNumber('210', '2100'), isFalse);
    expect(sameNumber('4165550100,1234', '416-555-0100'), isTrue);
    expect(sameNumber('4165550100', '4165550199'), isFalse);
    expect(sameNumber('', '210'), isFalse);
  });
}
