import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../accounts/domain/account_line.dart';
import '../../accounts/presentation/accounts_controller.dart';
import '../../session/presentation/session_controller.dart';
import '../domain/messaging_platform.dart';

/// The accounts that can send and receive texts. Either account may or may not
/// have messaging switched on and a number assigned, so each is judged alone:
/// the Messages tab appears when this is not empty, and the line tags and
/// filter only when it holds both.
final messagingLinesProvider = Provider<List<AccountLine>>((ref) {
  final primary = ref.watch(sessionControllerProvider).value?.carrierMessaging;
  final second = ref
      .watch(accountsControllerProvider)
      .value
      ?.secondary
      ?.carrierMessaging;
  return [
    if (isCarrierMessagingEnabled(primary)) AccountLine.primary,
    if (isCarrierMessagingEnabled(second)) AccountLine.secondary,
  ];
});

/// Which account's messages the user is looking at (only chosen by hand when
/// both accounts can message).
final messagingLineSelectionProvider =
    NotifierProvider<MessagingLineSelection, AccountLine?>(
      MessagingLineSelection.new,
    );

class MessagingLineSelection extends Notifier<AccountLine?> {
  @override
  AccountLine? build() => null;

  void select(AccountLine line) => state = line;
}

/// The account the Messages screens show: the chosen one if it can still
/// message, otherwise the first account that can.
final activeMessagingLineProvider = Provider<AccountLine>((ref) {
  final lines = ref.watch(messagingLinesProvider);
  final selected = ref.watch(messagingLineSelectionProvider);
  if (selected != null && lines.contains(selected)) return selected;
  return lines.firstOrNull ?? AccountLine.primary;
});
