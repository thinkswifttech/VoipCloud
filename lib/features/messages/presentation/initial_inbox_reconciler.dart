import '../domain/carrier_message.dart';
import '../domain/messaging_repository.dart';

class InitialInboxReconciliation {
  const InitialInboxReconciliation({
    required this.threads,
    required this.unreadByRemoteNumber,
  });

  final Map<String, List<CarrierMessage>> threads;
  final Map<String, int> unreadByRemoteNumber;
}

/// Reconciles the first server page as an authoritative index while retaining
/// messages already received for conversations that still exist.
InitialInboxReconciliation reconcileInitialInbox({
  required Map<String, List<CarrierMessage>> existingThreads,
  required MessagingInboxSnapshot inbox,
  Set<String> readOverrides = const {},
  Set<String> deletedOverrides = const {},
}) {
  final authoritativeRemotes = {
    ...inbox.remoteNumbers,
    ...inbox.blocksByRemoteNumber.keys,
  }..removeAll(deletedOverrides);
  return InitialInboxReconciliation(
    threads: {
      for (final remote in authoritativeRemotes)
        remote: existingThreads[remote] ?? const [],
    },
    unreadByRemoteNumber: {
      for (final entry in inbox.unreadByRemoteNumber.entries)
        if (!deletedOverrides.contains(entry.key))
          entry.key: readOverrides.contains(entry.key) ? 0 : entry.value,
    },
  );
}
