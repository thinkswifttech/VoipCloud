import 'package:flutter_riverpod/flutter_riverpod.dart';

class ContactsUiState {
  const ContactsUiState({this.query = '', this.queryUpdatedAt});

  final String query;
  final DateTime? queryUpdatedAt;

  ContactsUiState copyWith({
    String? query,
    DateTime? queryUpdatedAt,
    bool clearQueryUpdatedAt = false,
  }) {
    return ContactsUiState(
      query: query ?? this.query,
      queryUpdatedAt: clearQueryUpdatedAt
          ? null
          : queryUpdatedAt ?? this.queryUpdatedAt,
    );
  }
}

final contactsUiProvider =
    NotifierProvider<ContactsUiController, ContactsUiState>(
      ContactsUiController.new,
    );

class ContactsUiController extends Notifier<ContactsUiState> {
  static const searchRetention = Duration(minutes: 5);

  @override
  ContactsUiState build() => const ContactsUiState();

  void setQuery(String query) {
    final trimmed = query.trim();
    state = ContactsUiState(
      query: trimmed,
      queryUpdatedAt: trimmed.isEmpty ? null : DateTime.now(),
    );
  }

  /// Drops stale search text after [searchRetention] so returning from Dial
  /// soon after a search still restores it.
  void pruneStaleQuery() {
    final updatedAt = state.queryUpdatedAt;
    if (state.query.isEmpty || updatedAt == null) {
      return;
    }
    if (DateTime.now().difference(updatedAt) > searchRetention) {
      state = const ContactsUiState();
    }
  }
}
