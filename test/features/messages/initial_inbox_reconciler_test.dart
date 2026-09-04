import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/features/messages/domain/carrier_message.dart';
import 'package:phone_app/features/messages/domain/messaging_repository.dart';
import 'package:phone_app/features/messages/presentation/initial_inbox_reconciler.dart';

void main() {
  const active = '+14165550123';
  const deleted = '+14165550999';

  test('removes conversations absent from the authoritative first page', () {
    final result = reconcileInitialInbox(
      existingThreads: {
        active: [_message('active', active)],
        deleted: [_message('deleted', deleted)],
      },
      inbox: const MessagingInboxSnapshot(
        remoteNumbers: [active],
        unreadByRemoteNumber: {active: 2},
      ),
    );

    expect(result.threads.keys, [active]);
    expect(result.threads[active]!.single.id, 'active');
    expect(result.unreadByRemoteNumber, {active: 2});
  });

  test('does not let an in-flight snapshot undo read or delete actions', () {
    final result = reconcileInitialInbox(
      existingThreads: {
        active: [_message('active', active)],
        deleted: [_message('deleted', deleted)],
      },
      inbox: const MessagingInboxSnapshot(
        remoteNumbers: [active, deleted],
        unreadByRemoteNumber: {active: 3, deleted: 1},
      ),
      readOverrides: const {active},
      deletedOverrides: const {deleted},
    );

    expect(result.threads.keys, [active]);
    expect(result.unreadByRemoteNumber, {active: 0});
  });
}

CarrierMessage _message(String id, String remote) => CarrierMessage(
  id: id,
  remoteNumber: remote,
  direction: MessageDirection.incoming,
  text: 'Message',
  status: MessageStatus.received,
  createdAt: DateTime.utc(2026, 8, 13),
);
