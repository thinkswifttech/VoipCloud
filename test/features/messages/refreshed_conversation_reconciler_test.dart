import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/features/messages/domain/carrier_message.dart';
import 'package:phone_app/features/messages/presentation/refreshed_conversation_reconciler.dart';

void main() {
  const remote = '+14165550101';

  CarrierMessage message({
    required String id,
    required DateTime createdAt,
    String? clientId,
  }) => CarrierMessage(
    id: id,
    clientId: clientId,
    remoteNumber: remote,
    direction: MessageDirection.outgoing,
    text: id,
    status: MessageStatus.sent,
    createdAt: createdAt,
  );

  test('removes stale history absent from the authoritative refresh', () {
    final result = reconcileRefreshedConversation(
      existing: [message(id: 'deleted', createdAt: DateTime.utc(2026, 8, 23))],
      authoritative: [
        message(id: 'current', createdAt: DateTime.utc(2026, 8, 24)),
      ],
    );

    expect(result.map((item) => item.id), ['current']);
  });

  test('preserves an unsynchronized local send without duplicating it', () {
    final pending = message(
      id: 'client-1',
      clientId: 'client-1',
      createdAt: DateTime.utc(2026, 8, 24, 12),
    );
    final resultBeforeAcceptance = reconcileRefreshedConversation(
      existing: [pending],
      authoritative: [
        message(id: 'server-1', createdAt: DateTime.utc(2026, 8, 24, 11)),
      ],
    );
    expect(resultBeforeAcceptance.map((item) => item.id), [
      'server-1',
      'client-1',
    ]);

    final accepted = message(
      id: 'accepted-1',
      clientId: 'client-1',
      createdAt: DateTime.utc(2026, 8, 24, 12),
    );
    final resultAfterAcceptance = reconcileRefreshedConversation(
      existing: [pending],
      authoritative: [accepted],
    );
    expect(resultAfterAcceptance.map((item) => item.id), ['accepted-1']);
  });
}
