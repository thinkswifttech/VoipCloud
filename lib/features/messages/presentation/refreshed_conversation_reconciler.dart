import '../domain/carrier_message.dart';

List<CarrierMessage> reconcileRefreshedConversation({
  required List<CarrierMessage> existing,
  required List<CarrierMessage> authoritative,
}) {
  final serverClientIds = authoritative
      .map((message) => message.clientId)
      .whereType<String>()
      .toSet();
  final localPending = existing.where(
    (message) =>
        message.clientId != null &&
        message.id == message.clientId &&
        !serverClientIds.contains(message.clientId),
  );
  return [...authoritative, ...localPending]
    ..sort((left, right) => left.createdAt.compareTo(right.createdAt));
}
