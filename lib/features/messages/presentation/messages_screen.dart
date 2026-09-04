import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/errors/app_exception.dart';
import '../../../features/calls/presentation/caller_avatar.dart';
import '../../../features/calls/presentation/caller_identity.dart';
import '../../../features/contacts/domain/contact.dart';
import '../../../features/contacts/presentation/contacts_providers.dart';
import '../../../features/directory/domain/directory_entry.dart';
import '../../../features/directory/presentation/directory_providers.dart';
import '../../../features/messages/domain/carrier_message.dart';
import '../../../features/messages/domain/sms_compatibility.dart';
import '../../../shared/icons/app_icons.dart';
import '../../../shared/platform/desktop_platform.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/page_content.dart';
import 'message_thread_screen.dart';
import 'messages_providers.dart';

class MessagesScreen extends ConsumerStatefulWidget {
  const MessagesScreen({
    super.key,
    this.initialDestination,
    this.initialMessageId,
  });

  final String? initialDestination;
  final String? initialMessageId;

  @override
  ConsumerState<MessagesScreen> createState() => _MessagesScreenState();
}

class _MessagesScreenState extends ConsumerState<MessagesScreen> {
  bool _showNewMessageLabel = true;
  Timer? _collapseNewMessageTimer;
  String? _openedInitialDestination;
  String? _openedInitialMessageId;
  bool _isOpeningInitialMessage = false;

  @override
  void initState() {
    super.initState();
    _collapseNewMessageTimer = Timer(const Duration(milliseconds: 1800), () {
      if (mounted) setState(() => _showNewMessageLabel = false);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _openInitialDestination();
      _openInitialMessage();
    });
  }

  @override
  void didUpdateWidget(covariant MessagesScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialDestination != oldWidget.initialDestination) {
      _openedInitialDestination = null;
      _openInitialDestination();
    }
    if (widget.initialMessageId != oldWidget.initialMessageId) {
      _openedInitialMessageId = null;
      _openInitialMessage();
    }
  }

  @override
  void dispose() {
    _collapseNewMessageTimer?.cancel();
    super.dispose();
  }

  void _openInitialDestination() {
    final destination = widget.initialDestination?.trim() ?? '';
    if (destination.isEmpty || destination == _openedInitialDestination) {
      return;
    }
    _openedInitialDestination = destination;
    final uri = ref
        .read(messagesControllerProvider.notifier)
        .destinationForRaw(destination);
    _openThread(uri);
  }

  Future<void> _openInitialMessage() async {
    final messageId = widget.initialMessageId?.trim() ?? '';
    final messaging = ref.read(messagesControllerProvider);
    if (messageId.isEmpty ||
        messageId == _openedInitialMessageId ||
        _isOpeningInitialMessage ||
        messaging.availability != MessagingAvailability.ready ||
        messaging.isLoading) {
      return;
    }
    _isOpeningInitialMessage = true;
    final remote = await ref
        .read(messagesControllerProvider.notifier)
        .remoteNumberForMessage(messageId);
    _isOpeningInitialMessage = false;
    if (!mounted || remote == null || remote.isEmpty) return;
    _openedInitialMessageId = messageId;
    await _openThread(remote);
  }

  Future<void> _openThread(String remoteNumber) async {
    final number = remoteNumber.trim();
    if (number.isEmpty) return;
    ref.read(messagesControllerProvider.notifier).ensureThread(number);
    await ref
        .read(messagesControllerProvider.notifier)
        .markConversationRead(number);
    if (!mounted) return;
    await Navigator.of(context, rootNavigator: true).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => MessageThreadScreen(remoteNumber: number),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final messaging = ref.watch(messagesControllerProvider);
    ref.listen(messagesControllerProvider, (_, _) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _openInitialMessage(),
      );
    });
    final threads = messaging.threads;
    final contacts = ref.watch(contactsProvider).value ?? const [];
    final directory = ref.watch(directoryProvider).value ?? const [];

    final baseTheme = Theme.of(context);
    final messagesTheme = baseTheme.copyWith(
      textTheme: baseTheme.textTheme.apply(fontFamily: AppTheme.bodyFontFamily),
    );
    return Theme(
      data: messagesTheme,
      child: PageContent(
        maxWidth: 680,
        scrollable: false,
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: messaging.isLoading
            ? Center(
                child: Semantics(
                  label: 'Loading messages',
                  child: const CircularProgressIndicator(),
                ),
              )
            : messaging.availability == MessagingAvailability.ready
            ? _ConversationList(
                threads: threads,
                contacts: contacts,
                directory: directory,
                unreadByRemoteNumber: messaging.unreadByRemoteNumber,
                blockedNumbers: messaging.blocksByRemoteNumber.keys.toSet(),
                canStartConversation: messaging.canSend,
                syncError: messaging.errorMessage,
                showNewMessageLabel: _showNewMessageLabel,
                onOpenThread: _openThread,
                onBlock: _blockConversation,
                onDelete: _deleteConversation,
                onNewConversation: _showNewMessageSheet,
                onRefresh: () =>
                    ref.read(messagesControllerProvider.notifier).refresh(),
                hasMore: messaging.nextConversationCursor != null,
                isLoadingMore: messaging.isLoadingMoreConversations,
                onLoadMore: () => unawaited(
                  ref
                      .read(messagesControllerProvider.notifier)
                      .loadMoreConversations(),
                ),
              )
            : _MessagingReadinessState(state: messaging),
      ),
    );
  }

  Future<void> _blockConversation(String remoteNumber) async {
    try {
      await ref
          .read(messagesControllerProvider.notifier)
          .blockNumber(remoteNumber);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('SMS and MMS from this number blocked')),
      );
    } on AppException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.userMessage)));
    }
  }

  Future<bool> _deleteConversation(String remoteNumber) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete conversation?'),
        content: const Text(
          'Delete this conversation from the app? Messages on the other phone will not be deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return false;
    try {
      await ref
          .read(messagesControllerProvider.notifier)
          .deleteConversation(remoteNumber);
      return true;
    } on AppException catch (error) {
      if (!mounted) return false;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.userMessage)));
      return false;
    }
  }

  Future<void> _showNewMessageSheet() {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (_) => _NewMessageSourceSheet(onSelected: _openThread),
    );
  }
}

class _MessagingReadinessState extends StatelessWidget {
  const _MessagingReadinessState({required this.state});

  final MessagesState state;

  @override
  Widget build(BuildContext context) {
    final (title, message) = switch (state.availability) {
      MessagingAvailability.unsupportedPlatform => (
        'Messages unavailable',
        'SMS and MMS are not available on this device.',
      ),
      MessagingAvailability.notProvisioned => (
        'Messaging is not assigned',
        'Ask your administrator to assign a mobile number.',
      ),
      MessagingAvailability.suspended => (
        'Messaging is suspended',
        'Contact support to restore messaging.',
      ),
      MessagingAvailability.incompleteProvisioning => (
        'Messaging setup needs to be refreshed',
        'Sign out and scan a new activation code.',
      ),
      MessagingAvailability.integrationPending => (
        'Messaging service is being connected',
        'Messaging is not ready yet. Try again later.',
      ),
      MessagingAvailability.ready => ('Messages', ''),
    };
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: EmptyState(
          framed: false,
          icon: AppIcons.messages,
          title: title,
          message: message,
        ),
      ),
    );
  }
}

class _ConversationList extends StatefulWidget {
  const _ConversationList({
    required this.threads,
    required this.contacts,
    required this.directory,
    required this.unreadByRemoteNumber,
    required this.blockedNumbers,
    required this.canStartConversation,
    required this.syncError,
    required this.showNewMessageLabel,
    required this.onOpenThread,
    required this.onBlock,
    required this.onDelete,
    required this.onNewConversation,
    required this.onRefresh,
    required this.hasMore,
    required this.isLoadingMore,
    required this.onLoadMore,
  });

  final Map<String, List<CarrierMessage>> threads;
  final List<Contact> contacts;
  final List<DirectoryEntry> directory;
  final Map<String, int> unreadByRemoteNumber;
  final Set<String> blockedNumbers;
  final bool canStartConversation;
  final String? syncError;
  final bool showNewMessageLabel;
  final ValueChanged<String> onOpenThread;
  final Future<void> Function(String remoteNumber) onBlock;
  final Future<bool> Function(String remoteNumber) onDelete;
  final VoidCallback onNewConversation;
  final Future<void> Function() onRefresh;
  final bool hasMore;
  final bool isLoadingMore;
  final VoidCallback onLoadMore;

  @override
  State<_ConversationList> createState() => _ConversationListState();
}

class _ConversationListState extends State<_ConversationList> {
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode(debugLabel: 'message conversation search');
  final _keyboardFocusNode = FocusNode(
    debugLabel: 'messages keyboard shortcuts',
  );
  final _scrollController = ScrollController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_loadMoreIfNeeded);
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    _keyboardFocusNode.dispose();
    _scrollController
      ..removeListener(_loadMoreIfNeeded)
      ..dispose();
    super.dispose();
  }

  void _loadMoreIfNeeded() {
    if (!widget.hasMore ||
        widget.isLoadingMore ||
        !_scrollController.hasClients) {
      return;
    }
    final position = _scrollController.position;
    if (position.pixels >= position.maxScrollExtent - 240) {
      widget.onLoadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final desktopInteractions = isSupportedDesktopPlatform();
    final allEntries = widget.threads.entries.toList()
      ..sort((a, b) {
        final aTime = a.value.isEmpty ? DateTime(0) : a.value.last.createdAt;
        final bTime = b.value.isEmpty ? DateTime(0) : b.value.last.createdAt;
        return bTime.compareTo(aTime);
      });
    final normalizedQuery = _query.trim().toLowerCase();
    final entries = normalizedQuery.isEmpty
        ? allEntries
        : allEntries
              .where((entry) {
                final identity = resolveRemoteIdentity(
                  remoteUri: entry.key,
                  contacts: widget.contacts,
                  directory: widget.directory,
                );
                final latestText = entry.value.isEmpty
                    ? ''
                    : entry.value.last.text;
                return entry.key.toLowerCase().contains(normalizedQuery) ||
                    identity.label.toLowerCase().contains(normalizedQuery) ||
                    identity.number.toLowerCase().contains(normalizedQuery) ||
                    latestText.toLowerCase().contains(normalizedQuery);
              })
              .toList(growable: false);

    final content = Column(
      children: [
        if (allEntries.isNotEmpty || desktopInteractions) ...[
          Row(
            children: [
              Expanded(
                child: allEntries.isEmpty
                    ? const SizedBox.shrink()
                    : TextField(
                        controller: _searchController,
                        focusNode: _searchFocusNode,
                        onChanged: (value) => setState(() => _query = value),
                        onTapOutside: (_) =>
                            FocusManager.instance.primaryFocus?.unfocus(),
                        decoration: InputDecoration(
                          hintText: 'Search conversations',
                          prefixIcon: const Icon(Icons.search),
                          suffixIcon: _query.isEmpty
                              ? null
                              : IconButton(
                                  tooltip: 'Clear search',
                                  onPressed: () {
                                    _searchController.clear();
                                    setState(() => _query = '');
                                  },
                                  icon: const Icon(AppIcons.close),
                                ),
                        ),
                      ),
              ),
              if (desktopInteractions) ...[
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Refresh messages (F5)',
                  onPressed: () => unawaited(widget.onRefresh()),
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
        ],
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              RefreshIndicator(
                onRefresh: widget.onRefresh,
                child: entries.isEmpty
                    ? CustomScrollView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        slivers: [
                          SliverFillRemaining(
                            hasScrollBody: false,
                            child: Center(
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 340,
                                ),
                                child: EmptyState(
                                  framed: false,
                                  icon: AppIcons.messages,
                                  title: allEntries.isEmpty
                                      ? 'No conversations yet'
                                      : 'No matching conversations',
                                  message: allEntries.isNotEmpty
                                      ? 'Try a different search.'
                                      : widget.syncError != null
                                      ? 'Messages could not be synchronized. Check your connection and try again.'
                                      : widget.canStartConversation
                                      ? 'Choose a contact or enter a mobile number.'
                                      : 'Your message history will appear here. Sending will become available when carrier delivery is enabled.',
                                  action:
                                      allEntries.isEmpty &&
                                          widget.syncError != null
                                      ? FilledButton.icon(
                                          onPressed: () =>
                                              unawaited(widget.onRefresh()),
                                          icon: const Icon(Icons.refresh),
                                          label: const Text('Try again'),
                                        )
                                      : allEntries.isEmpty &&
                                            widget.canStartConversation
                                      ? FilledButton.icon(
                                          onPressed: widget.onNewConversation,
                                          icon: const Icon(
                                            AppIcons.newMessage,
                                            size: AppIconSize.sm,
                                          ),
                                          label: const Text('New message'),
                                        )
                                      : null,
                                ),
                              ),
                            ),
                          ),
                        ],
                      )
                    : ListView.builder(
                        controller: _scrollController,
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.only(bottom: 88),
                        itemCount: entries.length,
                        itemBuilder: (context, index) {
                          final entry = entries[index];
                          final latest = entry.value.isEmpty
                              ? null
                              : entry.value.last;
                          final identity = resolveRemoteIdentity(
                            remoteUri: entry.key,
                            contacts: widget.contacts,
                            directory: widget.directory,
                          );
                          final unread =
                              widget.unreadByRemoteNumber[entry.key] ?? 0;
                          final status = latest == null
                              ? null
                              : Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Text(
                                      _listTimeLabel(latest.createdAt),
                                      style: theme.textTheme.labelSmall
                                          ?.copyWith(
                                            color: theme
                                                .colorScheme
                                                .onSurfaceVariant,
                                          ),
                                    ),
                                    if (unread > 0) ...[
                                      const SizedBox(height: 4),
                                      Badge(label: Text('$unread')),
                                    ],
                                  ],
                                );
                          final tile = Material(
                            color: theme.colorScheme.surface,
                            child: ListTile(
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 2,
                              ),
                              leading: CallerAvatar(
                                identity: identity,
                                radius: 22,
                              ),
                              title: Text(
                                identity.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyLarge?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              subtitle: Text(
                                _conversationPreview(latest, identity),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: latest != null
                                    ? theme.textTheme.bodyMedium
                                    : AppTheme.numberStyle(
                                        theme.textTheme.bodyMedium,
                                      ),
                              ),
                              trailing: desktopInteractions
                                  ? Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        ?status,
                                        const SizedBox(width: 8),
                                        PopupMenuButton<_ConversationAction>(
                                          tooltip: 'Conversation actions',
                                          onSelected: (action) {
                                            switch (action) {
                                              case _ConversationAction.block:
                                                unawaited(
                                                  widget.onBlock(entry.key),
                                                );
                                              case _ConversationAction.delete:
                                                unawaited(
                                                  widget
                                                      .onDelete(entry.key)
                                                      .then<void>((_) {}),
                                                );
                                            }
                                          },
                                          itemBuilder: (context) => [
                                            if (!widget.blockedNumbers.contains(
                                              entry.key,
                                            ))
                                              const PopupMenuItem(
                                                value:
                                                    _ConversationAction.block,
                                                child: ListTile(
                                                  contentPadding:
                                                      EdgeInsets.zero,
                                                  leading: Icon(Icons.block),
                                                  title: Text('Block'),
                                                ),
                                              ),
                                            const PopupMenuItem(
                                              value: _ConversationAction.delete,
                                              child: ListTile(
                                                contentPadding: EdgeInsets.zero,
                                                leading: Icon(AppIcons.trash),
                                                title: Text('Delete'),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    )
                                  : status,
                              onTap: () => widget.onOpenThread(entry.key),
                            ),
                          );
                          if (desktopInteractions) return tile;
                          return Dismissible(
                            key: ValueKey('conversation-${entry.key}'),
                            direction: widget.blockedNumbers.contains(entry.key)
                                ? DismissDirection.endToStart
                                : DismissDirection.horizontal,
                            confirmDismiss: (direction) async {
                              if (direction == DismissDirection.startToEnd) {
                                await widget.onBlock(entry.key);
                                return false;
                              }
                              return widget.onDelete(entry.key);
                            },
                            background: const _ConversationSwipeAction(
                              alignment: Alignment.centerLeft,
                              color: Color(0xFF596579),
                              icon: Icons.block,
                              label: 'Block',
                            ),
                            secondaryBackground: _ConversationSwipeAction(
                              alignment: Alignment.centerRight,
                              color: theme.colorScheme.error,
                              icon: AppIcons.trash,
                              label: 'Delete',
                            ),
                            child: tile,
                          );
                        },
                      ),
              ),
              if (allEntries.isNotEmpty && widget.canStartConversation)
                Positioned(
                  right: 8,
                  bottom: 8,
                  child: _CollapsingNewMessageButton(
                    onPressed: widget.onNewConversation,
                    expanded: widget.showNewMessageLabel,
                  ),
                ),
              if (widget.isLoadingMore)
                const Positioned(
                  left: 0,
                  right: 0,
                  bottom: 8,
                  child: Center(child: CircularProgressIndicator()),
                ),
            ],
          ),
        ),
      ],
    );
    if (!desktopInteractions) return content;
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): () {
          _searchFocusNode.requestFocus();
          _searchController.selection = TextSelection(
            baseOffset: 0,
            extentOffset: _searchController.text.length,
          );
        },
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true): () {
          _searchFocusNode.requestFocus();
          _searchController.selection = TextSelection(
            baseOffset: 0,
            extentOffset: _searchController.text.length,
          );
        },
        const SingleActivator(LogicalKeyboardKey.keyN, control: true): () {
          if (widget.canStartConversation) widget.onNewConversation();
        },
        const SingleActivator(LogicalKeyboardKey.keyN, meta: true): () {
          if (widget.canStartConversation) widget.onNewConversation();
        },
        const SingleActivator(LogicalKeyboardKey.f5): () =>
            unawaited(widget.onRefresh()),
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_query.isNotEmpty) {
            _searchController.clear();
            setState(() => _query = '');
          } else {
            FocusManager.instance.primaryFocus?.unfocus();
          }
        },
      },
      child: Focus(
        focusNode: _keyboardFocusNode,
        autofocus: true,
        child: FocusTraversalGroup(child: content),
      ),
    );
  }
}

enum _ConversationAction { block, delete }

class _ConversationSwipeAction extends StatelessWidget {
  const _ConversationSwipeAction({
    required this.alignment,
    required this.color,
    required this.icon,
    required this.label,
  });

  final Alignment alignment;
  final Color color;
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      alignment: alignment,
      padding: const EdgeInsets.symmetric(horizontal: 22),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(color: Colors.white)),
        ],
      ),
    );
  }
}

class _CollapsingNewMessageButton extends StatelessWidget {
  const _CollapsingNewMessageButton({
    required this.onPressed,
    required this.expanded,
  });

  final VoidCallback onPressed;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: 'New message',
      child: Tooltip(
        message: 'New message',
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeInOutCubic,
          width: expanded ? 156 : 56,
          height: 56,
          decoration: BoxDecoration(
            color: scheme.primary,
            borderRadius: BorderRadius.circular(28),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.18),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onPressed,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(AppIcons.newMessage, color: scheme.onPrimary),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 260),
                    curve: Curves.easeInOutCubic,
                    child: expanded
                        ? Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: Text(
                              'New message',
                              maxLines: 1,
                              style: Theme.of(context).textTheme.labelLarge
                                  ?.copyWith(color: scheme.onPrimary),
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NewMessageSourceSheet extends StatelessWidget {
  const _NewMessageSourceSheet({required this.onSelected});

  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        4,
        20,
        20 + MediaQuery.paddingOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('New message', style: theme.textTheme.titleLarge),
          const SizedBox(height: 6),
          Text(
            'Choose who to message.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              AppIcons.navContacts,
              color: theme.colorScheme.primary,
            ),
            title: const Text('From contacts'),
            subtitle: const Text('Message someone from your phone contacts'),
            trailing: const Icon(AppIcons.chevronRight),
            onTap: () async {
              Navigator.of(context).pop();
              final destination = await showModalBottomSheet<String>(
                context: context,
                isScrollControlled: true,
                useSafeArea: true,
                showDragHandle: true,
                backgroundColor: theme.colorScheme.surface,
                builder: (_) => const _PickContactForMessageSheet(),
              );
              if (destination != null && destination.isNotEmpty) {
                onSelected(destination);
              }
            },
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(AppIcons.add, color: theme.colorScheme.primary),
            title: const Text('Someone new'),
            subtitle: const Text('Enter a mobile number'),
            trailing: const Icon(AppIcons.chevronRight),
            onTap: () async {
              Navigator.of(context).pop();
              final destination = await showModalBottomSheet<String>(
                context: context,
                isScrollControlled: true,
                useSafeArea: true,
                showDragHandle: true,
                backgroundColor: theme.colorScheme.surface,
                builder: (_) => const _NewNumberForMessageSheet(),
              );
              if (destination != null && destination.isNotEmpty) {
                onSelected(destination);
              }
            },
          ),
        ],
      ),
    );
  }
}

class _PickContactForMessageSheet extends ConsumerStatefulWidget {
  const _PickContactForMessageSheet();

  @override
  ConsumerState<_PickContactForMessageSheet> createState() =>
      _PickContactForMessageSheetState();
}

class _PickContactForMessageSheetState
    extends ConsumerState<_PickContactForMessageSheet> {
  final _queryController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final contacts = ref.watch(contactsProvider).value ?? const <Contact>[];
    final filtered = _filterContacts(contacts, _query);

    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.75,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'From contacts',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _queryController,
              autofocus: isSupportedDesktopPlatform(),
              onChanged: (value) => setState(() => _query = value.trim()),
              onTapOutside: (_) =>
                  FocusManager.instance.primaryFocus?.unfocus(),
              decoration: InputDecoration(
                hintText: 'Search contacts',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        onPressed: () {
                          _queryController.clear();
                          setState(() => _query = '');
                        },
                        icon: const Icon(AppIcons.close),
                      ),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: filtered.isEmpty
                  ? const Center(
                      child: EmptyState(
                        framed: false,
                        icon: AppIcons.navContacts,
                        title: 'No contacts found',
                        message:
                            'Try a different search, or message someone new.',
                      ),
                    )
                  : ListView.separated(
                      itemCount: filtered.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final contact = filtered[index];
                        final phones = contact.dialablePhones;
                        final subtitle = phones.isEmpty
                            ? 'No number'
                            : phones.length == 1
                            ? phones.first.number
                            : '${phones.length} numbers';
                        final identity = CallerIdentity(
                          label: contact.displayName.trim().isEmpty
                              ? (phones.isEmpty
                                    ? 'Unknown'
                                    : phones.first.number)
                              : contact.displayName.trim(),
                          number: phones.isEmpty ? '' : phones.first.number,
                          isResolvedName: contact.displayName.trim().isNotEmpty,
                          photo: contact.photo,
                        );
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: CallerAvatar(identity: identity, radius: 20),
                          title: Text(identity.label),
                          subtitle: Text(
                            subtitle,
                            style: AppTheme.numberStyle(
                              Theme.of(context).textTheme.bodyMedium,
                            ),
                          ),
                          enabled: phones.isNotEmpty,
                          onTap: phones.isEmpty
                              ? null
                              : () => _onContactTapped(contact, phones),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _onContactTapped(
    Contact contact,
    List<ContactPhone> phones,
  ) async {
    String? number;
    if (phones.length == 1) {
      number = phones.first.number;
    } else {
      number = await showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        builder: (sheetContext) {
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                    child: Text(
                      'Message which number?',
                      style: Theme.of(sheetContext).textTheme.titleMedium,
                    ),
                  ),
                  for (final phone in phones)
                    ListTile(
                      leading: const Icon(AppIcons.messages),
                      title: Text(phone.number),
                      subtitle: Text(phone.label),
                      onTap: () => Navigator.of(sheetContext).pop(phone.number),
                    ),
                ],
              ),
            ),
          );
        },
      );
    }
    if (number == null || number.isEmpty || !mounted) {
      return;
    }
    final destination = ref
        .read(messagesControllerProvider.notifier)
        .destinationForRaw(number);
    Navigator.of(context).pop(destination);
  }

  List<Contact> _filterContacts(List<Contact> contacts, String query) {
    if (query.isEmpty) {
      return contacts;
    }
    final lower = query.toLowerCase();
    return contacts.where((contact) {
      return contact.displayName.toLowerCase().contains(lower) ||
          contact.phoneNumber.toLowerCase().contains(lower) ||
          (contact.extension?.toLowerCase().contains(lower) ?? false) ||
          contact.dialablePhones.any(
            (phone) => phone.number.toLowerCase().contains(lower),
          );
    }).toList();
  }
}

class _PickDirectoryForMessageSheet extends ConsumerStatefulWidget {
  const _PickDirectoryForMessageSheet();

  @override
  ConsumerState<_PickDirectoryForMessageSheet> createState() =>
      _PickDirectoryForMessageSheetState();
}

class _PickDirectoryForMessageSheetState
    extends ConsumerState<_PickDirectoryForMessageSheet> {
  final _queryController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final directory = ref.watch(directoryProvider);

    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.75,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'From directory',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _queryController,
              autofocus: isSupportedDesktopPlatform(),
              onChanged: (value) => setState(() => _query = value.trim()),
              onTapOutside: (_) =>
                  FocusManager.instance.primaryFocus?.unfocus(),
              decoration: InputDecoration(
                hintText: 'Search directory',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        onPressed: () {
                          _queryController.clear();
                          setState(() => _query = '');
                        },
                        icon: const Icon(AppIcons.close),
                      ),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: directory.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (_, _) => const Center(
                  child: EmptyState(
                    framed: false,
                    icon: AppIcons.navDirectory,
                    title: 'Directory unavailable',
                    message: 'Could not load directory entries.',
                  ),
                ),
                data: (entries) {
                  final filtered = _filterDirectory(entries, _query);
                  if (filtered.isEmpty) {
                    return const Center(
                      child: EmptyState(
                        framed: false,
                        icon: AppIcons.navDirectory,
                        title: 'No matches',
                        message: 'Try a different search.',
                      ),
                    );
                  }
                  return ListView.separated(
                    itemCount: filtered.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final entry = filtered[index];
                      final identity = CallerIdentity(
                        label: entry.displayName.trim().isEmpty
                            ? entry.extension
                            : entry.displayName.trim(),
                        number: entry.extension,
                        isResolvedName: entry.displayName.trim().isNotEmpty,
                      );
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: CallerAvatar(identity: identity, radius: 20),
                        title: Text(identity.label),
                        subtitle: Text(
                          entry.extension,
                          style: AppTheme.numberStyle(
                            Theme.of(context).textTheme.bodyMedium,
                          ),
                        ),
                        onTap: () {
                          final destination = ref
                              .read(messagesControllerProvider.notifier)
                              .destinationForRaw(entry.extension);
                          Navigator.of(context).pop(destination);
                        },
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<DirectoryEntry> _filterDirectory(
    List<DirectoryEntry> entries,
    String query,
  ) {
    final controller = ref.read(messagesControllerProvider.notifier);
    final usable = entries
        .where(
          (entry) => controller.destinationForRaw(entry.extension).isNotEmpty,
        )
        .toList(growable: false);
    if (query.isEmpty) {
      return usable;
    }
    final lower = query.toLowerCase();
    return usable.where((entry) {
      return entry.displayName.toLowerCase().contains(lower) ||
          entry.extension.toLowerCase().contains(lower) ||
          entry.company.toLowerCase().contains(lower);
    }).toList();
  }
}

class _NewNumberForMessageSheet extends ConsumerStatefulWidget {
  const _NewNumberForMessageSheet();

  @override
  ConsumerState<_NewNumberForMessageSheet> createState() =>
      _NewNumberForMessageSheetState();
}

class _NewNumberForMessageSheetState
    extends ConsumerState<_NewNumberForMessageSheet> {
  final _numberController = TextEditingController();

  @override
  void dispose() {
    _numberController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return Padding(
      padding: EdgeInsets.fromLTRB(20, 4, 20, 20 + bottomInset),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Someone new', style: theme.textTheme.titleLarge),
          const SizedBox(height: 6),
          Text(
            'Enter a mobile number to message.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _numberController,
            autofocus: true,
            keyboardType: TextInputType.phone,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
            decoration: const InputDecoration(labelText: 'Mobile number'),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _submit,
            child: const Text('Start conversation'),
          ),
        ],
      ),
    );
  }

  void _submit() {
    final number = _numberController.text.trim();
    if (number.isEmpty) {
      return;
    }
    final destination = ref
        .read(messagesControllerProvider.notifier)
        .destinationForRaw(number);
    Navigator.of(context).pop(destination);
  }
}

String _conversationPreview(CarrierMessage? latest, CallerIdentity identity) {
  if (latest == null) {
    return identity.number.isNotEmpty && identity.number != identity.label
        ? identity.number
        : 'No messages yet';
  }
  if (latest.text.isNotEmpty) {
    final reaction = parseSmsReaction(latest.text);
    if (reaction != null) return 'Reacted ${reaction.kind.emoji}';
    return smsDisplayText(latest.text);
  }
  if (latest.attachments.isNotEmpty) {
    final attachment = latest.attachments.first;
    if (attachment.contentType.startsWith('image/')) return 'Photo';
    return attachment.fileName?.trim().isNotEmpty == true
        ? attachment.fileName!.trim()
        : 'Attachment';
  }
  return 'Message';
}

String _listTimeLabel(DateTime value) {
  final local = value.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  final delta = today.difference(day).inDays;
  if (delta == 0) {
    final hour24 = local.hour;
    final minute = local.minute.toString().padLeft(2, '0');
    final period = hour24 >= 12 ? 'PM' : 'AM';
    final hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12;
    return '$hour12:$minute $period';
  }
  if (delta == 1) {
    return 'Yesterday';
  }
  return '${local.month}/${local.day}';
}
