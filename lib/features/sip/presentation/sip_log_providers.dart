import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/sip_log_store.dart';
import '../domain/sip_log_entry.dart';

final sipLogStoreProvider = Provider<SipLogStore>((ref) {
  final store = SipLogStore();
  ref.onDispose(store.dispose);
  return store;
});

final sipLogEntriesProvider = StreamProvider<List<SipLogEntry>>((ref) {
  return ref.watch(sipLogStoreProvider).stream;
});
