import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter/services.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/files/downloads_saver.dart';
import '../../../features/calls/presentation/caller_avatar.dart';
import '../../../features/calls/presentation/caller_identity.dart';
import '../../../features/contacts/presentation/contacts_providers.dart';
import '../../../features/directory/presentation/directory_providers.dart';
import '../../../features/messages/domain/carrier_message.dart';
import '../../../features/messages/domain/messaging_repository.dart';
import '../../../features/messages/domain/sms_compatibility.dart';
import '../../../shared/icons/app_icons.dart';
import '../../../shared/platform/desktop_platform.dart';
import '../data/message_image_normalizer.dart';
import 'message_text_presentation.dart';
import 'messages_providers.dart';

class MessageThreadScreen extends ConsumerStatefulWidget {
  const MessageThreadScreen({required this.remoteNumber, super.key});

  final String remoteNumber;

  @override
  ConsumerState<MessageThreadScreen> createState() =>
      _MessageThreadScreenState();
}

class _MessageThreadScreenState extends ConsumerState<MessageThreadScreen> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  final _messagesScrollController = ScrollController();
  final Map<String, GlobalKey> _messageKeys = {};
  OutboundMessageAttachment? _attachment;
  CarrierMessage? _replyingTo;
  String? _draftClientId;
  bool _isSending = false;
  bool _isMarkingVisibleConversationRead = false;
  double? _uploadProgress;
  String? _highlightedMessageId;
  Timer? _highlightTimer;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_draftChanged);
    _messagesScrollController.addListener(_loadOlderIfNeeded);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref
          .read(messagesControllerProvider.notifier)
          .ensureThread(widget.remoteNumber);
      if (isSupportedDesktopPlatform() && mounted) {
        _focusNode.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    _controller.removeListener(_draftChanged);
    _highlightTimer?.cancel();
    _controller.dispose();
    _focusNode.dispose();
    _messagesScrollController
      ..removeListener(_loadOlderIfNeeded)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final baseTheme = Theme.of(context);
    final theme = baseTheme.copyWith(
      textTheme: baseTheme.textTheme.apply(fontFamily: AppTheme.bodyFontFamily),
      appBarTheme: baseTheme.appBarTheme.copyWith(
        backgroundColor: baseTheme.brightness == Brightness.dark
            ? const Color(0xFF1A1C21)
            : const Color(0xFFF3F4F6),
        titleTextStyle: baseTheme.textTheme.titleLarge?.copyWith(
          fontFamily: AppTheme.bodyFontFamily,
        ),
      ),
    );
    final messaging = ref.watch(messagesControllerProvider);
    ref.listen<int>(
      messagesControllerProvider.select(
        (value) => value.unreadByRemoteNumber[widget.remoteNumber] ?? 0,
      ),
      (_, unread) {
        if (unread > 0) _markVisibleConversationRead();
      },
    );
    final rawMessages =
        messaging.threads[widget.remoteNumber] ?? const <CarrierMessage>[];
    final threadPresentation = presentSmsThread(rawMessages);
    final messages = threadPresentation.messages;
    final messagesById = {for (final message in messages) message.id: message};
    final desktopInteractions = isSupportedDesktopPlatform();
    final isBlocked = messaging.isBlocked(widget.remoteNumber);
    final contactsState = ref.watch(contactsProvider);
    final contacts = contactsState.value ?? const [];
    final directory = ref.watch(directoryProvider).value ?? const [];
    final identity = resolveRemoteIdentity(
      remoteUri: widget.remoteNumber,
      contacts: contacts,
      directory: directory,
    );
    final isSavedContact = contacts.any(
      (contact) => contactMatchesRemoteIdentity(contact, widget.remoteNumber),
    );
    final canAddContact =
        !isSavedContact &&
        contactsState.hasValue &&
        identity.number.isNotEmpty &&
        ref.read(deviceContactsRepositoryProvider).isSupported;

    return Theme(
      data: theme,
      child: Scaffold(
        backgroundColor: theme.brightness == Brightness.dark
            ? const Color(0xFF0E1015)
            : Colors.white,
        appBar: AppBar(
          leading: IconButton(
            tooltip: 'Back',
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(AppIcons.back),
          ),
          titleSpacing: 0,
          title: Row(
            children: [
              CallerAvatar(
                identity: identity,
                radius: 18,
                backgroundColor: theme.brightness == Brightness.dark
                    ? const Color(0xFF303641)
                    : Colors.white,
                foregroundColor: theme.colorScheme.onSurface,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      identity.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (identity.number.isNotEmpty &&
                        identity.number != identity.label)
                      Text(
                        identity.number,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTheme.numberStyle(
                          theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            if (desktopInteractions)
              IconButton(
                tooltip: 'Refresh conversation (F5)',
                onPressed: () => unawaited(_refreshConversation()),
                icon: const Icon(Icons.refresh),
              ),
            PopupMenuButton<_ThreadAction>(
              tooltip: 'Conversation options',
              icon: const Icon(AppIcons.moreVertical),
              onSelected: (action) =>
                  _handleThreadAction(action, isBlocked, identity.number),
              itemBuilder: (_) => [
                if (canAddContact)
                  const PopupMenuItem(
                    value: _ThreadAction.addContact,
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.person_add_alt_1_outlined),
                      title: Text('Add to contacts'),
                    ),
                  ),
                PopupMenuItem(
                  value: isBlocked
                      ? _ThreadAction.unblock
                      : _ThreadAction.block,
                  child: Text(
                    isBlocked ? 'Unblock messages' : 'Block messages',
                  ),
                ),
              ],
            ),
          ],
        ),
        body: CallbackShortcuts(
          bindings: desktopInteractions
              ? <ShortcutActivator, VoidCallback>{
                  const SingleActivator(LogicalKeyboardKey.f5): () =>
                      unawaited(_refreshConversation()),
                  const SingleActivator(LogicalKeyboardKey.escape):
                      _cancelComposerContext,
                }
              : const <ShortcutActivator, VoidCallback>{},
          child: FocusTraversalGroup(
            child: Column(
              children: [
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: _refreshConversation,
                    child: messages.isEmpty
                        ? ListView(
                            physics: const AlwaysScrollableScrollPhysics(),
                            children: [
                              SizedBox(
                                height:
                                    MediaQuery.sizeOf(context).height * 0.45,
                                child: Center(
                                  child: Text(
                                    'No messages yet',
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          )
                        : Stack(
                            children: [
                              ListView.builder(
                                controller: _messagesScrollController,
                                reverse: true,
                                physics: const AlwaysScrollableScrollPhysics(),
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  12,
                                  16,
                                  12,
                                ),
                                itemCount: messages.length,
                                itemBuilder: (context, index) {
                                  final message =
                                      messages[messages.length - 1 - index];
                                  final previous = index + 1 < messages.length
                                      ? messages[messages.length - 2 - index]
                                      : null;
                                  final showDayHeader =
                                      previous == null ||
                                      !_sameDay(
                                        previous.createdAt,
                                        message.createdAt,
                                      );
                                  final replyTargetId =
                                      threadPresentation
                                          .replyTargetMessageIdByMessageId[message
                                          .id];
                                  final replyTarget =
                                      messagesById[replyTargetId];
                                  return KeyedSubtree(
                                    key: _messageKeys.putIfAbsent(
                                      message.id,
                                      GlobalKey.new,
                                    ),
                                    child: Column(
                                      children: [
                                        if (showDayHeader)
                                          _DayHeader(date: message.createdAt),
                                        _MessageBubble(
                                          message: message,
                                          replyTarget: replyTarget,
                                          highlighted:
                                              _highlightedMessageId ==
                                              message.id,
                                          reactions:
                                              threadPresentation
                                                  .reactionsByMessageId[message
                                                  .id] ??
                                              const [],
                                          onQuotedMessageTap:
                                              replyTarget == null
                                              ? null
                                              : () => _scrollToMessage(
                                                  replyTarget.id,
                                                  messages,
                                                ),
                                          onReply: _canReplyTo(message)
                                              ? () => _startReply(message)
                                              : null,
                                          onLongPress: () =>
                                              _showMessageActions(message),
                                          onRetry: message.canRetry
                                              ? () => _retryMessage(message)
                                              : null,
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                              if (messaging.loadingOlderThreads.contains(
                                widget.remoteNumber,
                              ))
                                const Align(
                                  alignment: Alignment.topCenter,
                                  child: Padding(
                                    padding: EdgeInsets.all(8),
                                    child: CircularProgressIndicator(),
                                  ),
                                ),
                            ],
                          ),
                  ),
                ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_replyingTo case final reply?) ...[
                          _ReplyComposerPreview(
                            message: reply,
                            onClose: _cancelReply,
                          ),
                          const SizedBox(height: 8),
                        ],
                        if (_attachment case final attachment?) ...[
                          _OutboundAttachmentPreview(
                            attachment: attachment,
                            enabled: !_isSending,
                            onRemove: _removeAttachment,
                          ),
                          if (_isSending && _uploadProgress != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: LinearProgressIndicator(
                                value: _uploadProgress,
                                semanticsLabel: 'Uploading attachment',
                              ),
                            ),
                          const SizedBox(height: 8),
                        ],
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            IconButton(
                              tooltip: messaging.canSendMms
                                  ? 'Attach a photo'
                                  : 'MMS is not enabled yet',
                              onPressed:
                                  messaging.canSendMms &&
                                      !isBlocked &&
                                      !_isSending
                                  ? _chooseAttachmentSource
                                  : null,
                              icon: const Icon(AppIcons.attachment),
                            ),
                            Expanded(
                              child: CallbackShortcuts(
                                bindings: desktopInteractions
                                    ? <ShortcutActivator, VoidCallback>{
                                        const SingleActivator(
                                          LogicalKeyboardKey.enter,
                                        ): () =>
                                            unawaited(_send()),
                                        const SingleActivator(
                                          LogicalKeyboardKey.numpadEnter,
                                        ): () =>
                                            unawaited(_send()),
                                        const SingleActivator(
                                          LogicalKeyboardKey.enter,
                                          control: true,
                                        ): () =>
                                            unawaited(_send()),
                                        const SingleActivator(
                                          LogicalKeyboardKey.enter,
                                          meta: true,
                                        ): () =>
                                            unawaited(_send()),
                                      }
                                    : const <ShortcutActivator, VoidCallback>{},
                                child: TextField(
                                  controller: _controller,
                                  focusNode: _focusNode,
                                  enabled:
                                      messaging.canSend &&
                                      !isBlocked &&
                                      !_isSending,
                                  minLines: 1,
                                  maxLines: 5,
                                  textInputAction: TextInputAction.newline,
                                  decoration: InputDecoration(
                                    hintText: isBlocked
                                        ? 'Messaging is blocked for this number'
                                        : messaging.canSend
                                        ? 'Message'
                                        : 'Sending is not enabled yet',
                                    filled: true,
                                    fillColor:
                                        theme.brightness == Brightness.dark
                                        ? const Color(0xFF1A1C20)
                                        : const Color(0xFFF3F4F6),
                                    enabledBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(22),
                                      borderSide: BorderSide(
                                        color: theme.colorScheme.outline
                                            .withValues(alpha: 0.35),
                                      ),
                                    ),
                                    focusedBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(22),
                                      borderSide: BorderSide(
                                        color: theme.colorScheme.outline
                                            .withValues(alpha: 0.55),
                                        width: 1.25,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            IconButton.filled(
                              tooltip: _isSending ? 'Sending' : 'Send',
                              onPressed:
                                  messaging.canSend && !isBlocked && !_isSending
                                  ? _send
                                  : null,
                              icon: _isSending
                                  ? SizedBox.square(
                                      dimension: AppIconSize.md,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: theme.colorScheme.onPrimary,
                                      ),
                                    )
                                  : const Icon(
                                      AppIcons.send,
                                      size: AppIconSize.md,
                                    ),
                              style: IconButton.styleFrom(
                                backgroundColor: theme.colorScheme.primary,
                                foregroundColor: theme.colorScheme.onPrimary,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _refreshConversation() => ref
      .read(messagesControllerProvider.notifier)
      .refreshConversation(widget.remoteNumber);

  void _cancelComposerContext() {
    if (_replyingTo != null || _attachment != null) {
      setState(() {
        _replyingTo = null;
        _attachment = null;
        _draftClientId = null;
        _uploadProgress = null;
      });
      _focusNode.requestFocus();
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
  }

  void _markVisibleConversationRead() {
    if (_isMarkingVisibleConversationRead) return;
    _isMarkingVisibleConversationRead = true;
    Future<void>.microtask(() async {
      if (!mounted) {
        _isMarkingVisibleConversationRead = false;
        return;
      }
      try {
        await ref
            .read(messagesControllerProvider.notifier)
            .markConversationRead(widget.remoteNumber);
      } finally {
        _isMarkingVisibleConversationRead = false;
      }
    });
  }

  void _draftChanged() {
    if (!_isSending) _draftClientId = null;
  }

  void _loadOlderIfNeeded() {
    if (!_messagesScrollController.hasClients) return;
    final position = _messagesScrollController.position;
    if (position.pixels < position.maxScrollExtent - 240) return;
    unawaited(
      ref
          .read(messagesControllerProvider.notifier)
          .loadOlderMessages(widget.remoteNumber),
    );
  }

  Future<void> _retryMessage(CarrierMessage message) async {
    try {
      await ref.read(messagesControllerProvider.notifier).retryMessage(message);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            error is AppException
                ? error.userMessage
                : 'This message could not be safely retried.',
          ),
        ),
      );
    }
  }

  Future<void> _handleThreadAction(
    _ThreadAction action,
    bool isBlocked,
    String phoneNumber,
  ) async {
    if (action == _ThreadAction.addContact) {
      await _addRemoteContact(phoneNumber);
      return;
    }
    final unblock = action == _ThreadAction.unblock;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(unblock ? 'Unblock messages?' : 'Block messages?'),
        content: Text(
          unblock
              ? 'SMS and MMS with this number will be allowed again.'
              : 'You will not receive SMS or MMS from this number. Calls are not affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(unblock ? 'Unblock' : 'Block'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final controller = ref.read(messagesControllerProvider.notifier);
      if (unblock) {
        await controller.unblockNumber(widget.remoteNumber);
      } else {
        await controller.blockNumber(widget.remoteNumber);
      }
    } on AppException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.userMessage)));
    }
  }

  Future<void> _addRemoteContact(String phoneNumber) async {
    try {
      final createdId = await ref
          .read(contactsProvider.notifier)
          .addContact(phoneNumber: phoneNumber);
      if (!mounted || createdId == null) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Contact added')));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not open the phone contact editor.'),
        ),
      );
    }
  }

  Future<void> _showMessageActions(CarrierMessage message) async {
    final reactionTarget = smsReactionTargetText(message);
    final allowReply = _canReplyTo(message);
    final action = await showModalBottomSheet<Object>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (reactionTarget.isNotEmpty && allowReply) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    for (final reaction in SmsReactionKind.values)
                      IconButton(
                        tooltip: 'React ${reaction.emoji}',
                        onPressed: () => Navigator.pop(context, reaction),
                        icon: Text(
                          reaction.emoji,
                          style: const TextStyle(fontSize: 24),
                        ),
                      ),
                  ],
                ),
              ),
              const Divider(height: 1),
            ],
            if (allowReply)
              ListTile(
                leading: const Icon(Icons.reply_rounded),
                title: const Text('Reply'),
                subtitle: const Text('Includes a readable quote'),
                onTap: () => Navigator.pop(context, _MessageAction.reply),
              ),
            if (message.text.isNotEmpty)
              ListTile(
                leading: const Icon(AppIcons.copy),
                title: const Text('Copy message'),
                onTap: () => Navigator.pop(context, _MessageAction.copy),
              ),
            ListTile(
              leading: Icon(
                AppIcons.trash,
                color: Theme.of(context).colorScheme.error,
              ),
              title: const Text('Delete message'),
              subtitle: const Text('Removes it from this app'),
              onTap: () => Navigator.pop(context, _MessageAction.delete),
            ),
          ],
        ),
      ),
    );
    if (action is SmsReactionKind) {
      await _sendReaction(message, action);
      return;
    }
    if (action == _MessageAction.reply) {
      _startReply(message);
      return;
    }
    if (action == _MessageAction.delete) {
      await _deleteMessage(message);
      return;
    }
    if (action != _MessageAction.copy) return;
    await Clipboard.setData(ClipboardData(text: message.text));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Message copied')));
  }

  bool _canReplyTo(CarrierMessage message) {
    if (message.direction == MessageDirection.incoming) return true;
    return message.status == MessageStatus.submitted ||
        message.status == MessageStatus.sent ||
        message.status == MessageStatus.delivered;
  }

  void _startReply(CarrierMessage message) {
    setState(() {
      _replyingTo = message;
      _draftClientId = null;
    });
    _focusNode.requestFocus();
  }

  void _cancelReply() {
    setState(() {
      _replyingTo = null;
      _draftClientId = null;
    });
  }

  Future<void> _sendReaction(
    CarrierMessage message,
    SmsReactionKind reaction,
  ) async {
    try {
      final fallback = formatSmsReaction(
        reaction,
        smsReactionTargetText(message),
      );
      await ref
          .read(messagesControllerProvider.notifier)
          .sendMessage(destination: widget.remoteNumber, text: fallback);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            error is AppException
                ? error.userMessage
                : 'The reaction could not be sent.',
          ),
        ),
      );
    }
  }

  Future<void> _deleteMessage(CarrierMessage message) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete message?'),
        content: const Text(
          'Delete this message from the app? It will stay on the other phone.',
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
    if (confirmed != true || !mounted) return;
    try {
      await ref
          .read(messagesControllerProvider.notifier)
          .deleteMessage(message);
    } on AppException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.userMessage)));
    }
  }

  Future<void> _chooseAttachmentSource() async {
    final source = isSupportedDesktopPlatform()
        ? ImageSource.gallery
        : await showModalBottomSheet<ImageSource>(
            context: context,
            showDragHandle: true,
            builder: (context) => SafeArea(
              child: Wrap(
                children: [
                  ListTile(
                    leading: const Icon(AppIcons.camera),
                    title: const Text('Take photo'),
                    onTap: () => Navigator.pop(context, ImageSource.camera),
                  ),
                  ListTile(
                    leading: const Icon(AppIcons.gallery),
                    title: const Text('Choose photo'),
                    onTap: () => Navigator.pop(context, ImageSource.gallery),
                  ),
                ],
              ),
            ),
          );
    if (source == null || !mounted) return;
    try {
      final messaging = ref.read(messagesControllerProvider);
      final file = await ImagePicker().pickImage(
        source: source,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 70,
      );
      if (file == null) return;
      final contentType = _normalizeImageMimeType(
        file.mimeType ?? _imageMimeType(file.name),
      );
      if (!messaging.outboundAttachmentMimeTypes.contains(contentType)) {
        throw const FormatException('This image type is not supported.');
      }
      final bytes = await normalizeMessageImage(
        bytes: await file.readAsBytes(),
        contentType: contentType,
        maximumBytes: messaging.maxOutboundAttachmentBytes,
        stripMetadata: true,
      );
      if (bytes.length > messaging.maxOutboundAttachmentBytes) {
        throw FormatException(
          'This photo is too large. Choose one smaller than '
          '${_fileSize(messaging.maxOutboundAttachmentBytes)}.',
        );
      }
      if (!mounted) return;
      setState(() {
        _attachment = OutboundMessageAttachment(
          bytes: bytes,
          fileName: _safeUploadName(file.name, contentType),
          contentType: contentType,
        );
        _draftClientId = null;
        _uploadProgress = null;
      });
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            error is FormatException
                ? error.message.toString()
                : 'The photo could not be attached.',
          ),
        ),
      );
    }
  }

  void _removeAttachment() {
    setState(() {
      _attachment = null;
      _draftClientId = null;
      _uploadProgress = null;
    });
  }

  Future<void> _send() async {
    final typedText = _controller.text.trim();
    final reply = _replyingTo;
    final text = reply == null
        ? typedText
        : formatSmsQuotedReply(
            quotedText: smsReplyTargetText(reply),
            response: typedText,
          );
    final attachment = _attachment;
    if (_isSending || (typedText.isEmpty && attachment == null)) return;
    final clientId =
        _draftClientId ?? 'app-${DateTime.now().microsecondsSinceEpoch}';
    _draftClientId = clientId;
    setState(() {
      _isSending = true;
      _uploadProgress = attachment == null ? null : 0;
    });
    try {
      await ref
          .read(messagesControllerProvider.notifier)
          .sendMessage(
            destination: widget.remoteNumber,
            text: text,
            attachment: attachment,
            clientId: clientId,
            onSendProgress: attachment == null
                ? null
                : (sent, total) {
                    if (!mounted || total <= 0) return;
                    setState(() {
                      _uploadProgress = (sent / total).clamp(0, 1);
                    });
                  },
          );
      if (!mounted) return;
      _controller.clear();
      setState(() {
        _attachment = null;
        _replyingTo = null;
        _draftClientId = null;
        _uploadProgress = null;
      });
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            error is AppException
                ? error.userMessage
                : attachment == null
                ? 'Message could not be sent. Tap send to retry.'
                : 'MMS could not be sent. Your photo is ready to retry.',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  Future<void> _scrollToMessage(
    String messageId,
    List<CarrierMessage> messages,
  ) async {
    var targetContext = _messageKeys[messageId]?.currentContext;
    if (targetContext == null && _messagesScrollController.hasClients) {
      final sourceIndex = messages.indexWhere((item) => item.id == messageId);
      if (sourceIndex >= 0 && messages.length > 1) {
        final reverseIndex = messages.length - 1 - sourceIndex;
        final position = _messagesScrollController.position;
        final estimatedOffset =
            position.maxScrollExtent * reverseIndex / (messages.length - 1);
        await _messagesScrollController.animateTo(
          estimatedOffset.clamp(0, position.maxScrollExtent),
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
        );
        await WidgetsBinding.instance.endOfFrame;
      }
    }
    if (!mounted) return;
    await _ensureMessageVisible(messageId);
    if (!mounted) return;
    _highlightTimer?.cancel();
    setState(() => _highlightedMessageId = messageId);
    _highlightTimer = Timer(const Duration(milliseconds: 1400), () {
      if (mounted && _highlightedMessageId == messageId) {
        setState(() => _highlightedMessageId = null);
      }
    });
  }

  Future<void> _ensureMessageVisible(String messageId) {
    final context = _messageKeys[messageId]?.currentContext;
    if (context == null) return Future<void>.value();
    return Scrollable.ensureVisible(
      context,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      alignment: 0.45,
    );
  }
}

class _ReplyComposerPreview extends StatelessWidget {
  const _ReplyComposerPreview({required this.message, required this.onClose});

  final CarrierMessage message;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final excerpt = smsCompatibilityExcerpt(smsReplyTargetText(message));
    final isPhoto = message.attachments.any(
      (attachment) => attachment.contentType.startsWith('image/'),
    );
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border(
          left: BorderSide(color: theme.colorScheme.primary, width: 3),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Replying to ${message.direction == MessageDirection.outgoing ? 'your message' : 'their message'}',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    if (isPhoto) ...[
                      Icon(
                        Icons.photo_outlined,
                        size: 16,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 5),
                    ],
                    Expanded(
                      child: Text(
                        excerpt,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Cancel reply',
            onPressed: onClose,
            icon: const Icon(AppIcons.close, size: AppIconSize.sm),
          ),
        ],
      ),
    );
  }
}

class _OutboundAttachmentPreview extends StatelessWidget {
  const _OutboundAttachmentPreview({
    required this.attachment,
    required this.enabled,
    required this.onRemove,
  });

  final OutboundMessageAttachment attachment;
  final bool enabled;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.memory(
              attachment.bytes,
              width: 64,
              height: 64,
              fit: BoxFit.cover,
              cacheWidth: 192,
              filterQuality: FilterQuality.medium,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  attachment.fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _fileSize(attachment.bytes.length),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Remove photo',
            onPressed: enabled ? onRemove : null,
            icon: const Icon(AppIcons.close),
          ),
        ],
      ),
    );
  }
}

String _imageMimeType(String name) {
  final lower = name.toLowerCase();
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
    return 'image/jpeg';
  }
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.gif')) return 'image/gif';
  if (lower.endsWith('.webp')) return 'image/webp';
  return 'application/octet-stream';
}

String _normalizeImageMimeType(String contentType) {
  return switch (contentType.trim().toLowerCase()) {
    'image/jpg' || 'image/pjpeg' => 'image/jpeg',
    final normalized => normalized,
  };
}

String _safeUploadName(String supplied, String contentType) {
  final name = supplied.split(RegExp(r'[/\\]')).last.trim();
  if (name.isNotEmpty && name.length <= 120) return name;
  final extension = switch (contentType) {
    'image/png' => 'png',
    'image/gif' => 'gif',
    'image/webp' => 'webp',
    _ => 'jpg',
  };
  return 'photo-${DateTime.now().millisecondsSinceEpoch}.$extension';
}

class _DayHeader extends StatelessWidget {
  const _DayHeader({required this.date});

  final DateTime date;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Text(
        _dayLabel(date),
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.reactions,
    required this.onLongPress,
    required this.highlighted,
    this.replyTarget,
    this.onQuotedMessageTap,
    this.onReply,
    this.onRetry,
  });

  final CarrierMessage message;
  final CarrierMessage? replyTarget;
  final List<SmsReactionPresentation> reactions;
  final VoidCallback onLongPress;
  final VoidCallback? onQuotedMessageTap;
  final VoidCallback? onReply;
  final VoidCallback? onRetry;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final outgoing = message.direction == MessageDirection.outgoing;
    final color = outgoing
        ? theme.brightness == Brightness.dark
              ? const Color(0xFF253248)
              : const Color(0xFFE7EEF9)
        : theme.colorScheme.surfaceContainerHighest;
    final foreground = outgoing
        ? theme.colorScheme.onSurface
        : theme.colorScheme.onSurface;

    final quotedReply = parseSmsQuotedReply(message.text);
    final displayedText = quotedReply?.response ?? message.text;
    final quotedPhoto =
        replyTarget?.attachments.any(
          (attachment) => attachment.contentType.startsWith('image/'),
        ) ??
        quotedReply?.quote.trim().toLowerCase() == 'photo';

    return _SwipeToReply(
      enabled: onReply != null,
      onReply: onReply,
      child: Align(
        alignment: outgoing ? Alignment.centerRight : Alignment.centerLeft,
        child: Padding(
          padding: EdgeInsets.only(bottom: reactions.isEmpty ? 8 : 20),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (isSupportedDesktopPlatform() && outgoing)
                _DesktopMessageActionsButton(onPressed: onLongPress),
              Flexible(
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    GestureDetector(
                      onTap: onRetry,
                      onSecondaryTap: onLongPress,
                      onLongPress: onLongPress,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        curve: Curves.easeOut,
                        constraints: const BoxConstraints(maxWidth: 420),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 9,
                        ),
                        decoration: BoxDecoration(
                          color: color,
                          border: highlighted
                              ? Border.all(
                                  color: theme.colorScheme.primary,
                                  width: 2,
                                )
                              : null,
                          boxShadow: highlighted
                              ? [
                                  BoxShadow(
                                    color: theme.colorScheme.primary.withValues(
                                      alpha: 0.24,
                                    ),
                                    blurRadius: 10,
                                    spreadRadius: 1,
                                  ),
                                ]
                              : null,
                          borderRadius: BorderRadius.only(
                            topLeft: const Radius.circular(14),
                            topRight: const Radius.circular(14),
                            bottomLeft: Radius.circular(outgoing ? 14 : 4),
                            bottomRight: Radius.circular(outgoing ? 4 : 14),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: outgoing
                              ? CrossAxisAlignment.end
                              : CrossAxisAlignment.start,
                          children: [
                            if (quotedReply case final quote?) ...[
                              _QuotedMessageBlock(
                                quote: quote.quote,
                                isPhoto: quotedPhoto,
                                onTap: onQuotedMessageTap,
                              ),
                              if (displayedText.isNotEmpty ||
                                  message.attachments.isNotEmpty)
                                const SizedBox(height: 8),
                            ],
                            for (final attachment in message.attachments)
                              Padding(
                                padding: EdgeInsets.only(
                                  bottom: displayedText.isEmpty ? 0 : 8,
                                ),
                                child: _MessageAttachmentView(
                                  key: ValueKey(attachment.id),
                                  attachment: attachment,
                                  foreground: foreground,
                                  sendFailed:
                                      outgoing &&
                                      message.status == MessageStatus.failed,
                                ),
                              ),
                            if (displayedText.isNotEmpty)
                              Builder(
                                builder: (context) {
                                  final presentation = messageTextPresentation(
                                    displayedText,
                                  );
                                  return Text(
                                    displayedText,
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: foreground,
                                      fontSize: presentation.fontSize,
                                      height: presentation.height,
                                    ),
                                  );
                                },
                              ),
                            const SizedBox(height: 4),
                            _MessageMeta(
                              message: message,
                              foreground: foreground.withValues(alpha: 0.72),
                            ),
                            if (onRetry != null) ...[
                              const SizedBox(height: 4),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.refresh,
                                    size: 14,
                                    color: foreground,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    'Tap to retry',
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: foreground,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    if (reactions.isNotEmpty)
                      Positioned(
                        right: 8,
                        bottom: -12,
                        child: _ReactionBadge(reactions: reactions),
                      ),
                  ],
                ),
              ),
              if (isSupportedDesktopPlatform() && !outgoing)
                _DesktopMessageActionsButton(onPressed: onLongPress),
            ],
          ),
        ),
      ),
    );
  }
}

class _DesktopMessageActionsButton extends StatelessWidget {
  const _DesktopMessageActionsButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: IconButton(
        tooltip: 'Message actions',
        visualDensity: VisualDensity.compact,
        iconSize: 18,
        onPressed: onPressed,
        icon: const Icon(Icons.more_horiz),
      ),
    );
  }
}

class _QuotedMessageBlock extends StatelessWidget {
  const _QuotedMessageBlock({
    required this.quote,
    required this.isPhoto,
    this.onTap,
  });

  final String quote;
  final bool isPhoto;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: onTap != null,
      label: onTap == null ? null : 'Go to replied message',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 320),
          padding: const EdgeInsets.fromLTRB(8, 3, 4, 3),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: theme.colorScheme.onSurfaceVariant.withValues(
                  alpha: 0.55,
                ),
                width: 2,
              ),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isPhoto) ...[
                Icon(
                  Icons.photo_outlined,
                  size: 16,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 5),
              ],
              Flexible(
                child: Text(
                  quote,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w500,
                    height: 1.25,
                    decoration: onTap == null ? null : TextDecoration.underline,
                    decorationColor: theme.colorScheme.onSurfaceVariant
                        .withValues(alpha: 0.45),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReactionBadge extends StatelessWidget {
  const _ReactionBadge({required this.reactions});

  final List<SmsReactionPresentation> reactions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pending = reactions.any((reaction) => reaction.isPending);
    final label = reactions
        .map((reaction) => reaction.kind.emoji)
        .join('\u2009');
    return Tooltip(
      message: pending ? 'Sending reaction' : 'Message reaction',
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 180),
        opacity: pending ? 0.68 : 1,
        child: Container(
          constraints: const BoxConstraints(minHeight: 26),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: theme.colorScheme.outlineVariant),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(
                  alpha: theme.brightness == Brightness.dark ? 0.28 : 0.1,
                ),
                blurRadius: 4,
                offset: const Offset(0, 1),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label, style: const TextStyle(fontSize: 15, height: 1.1)),
              if (pending) ...[
                const SizedBox(width: 4),
                SizedBox.square(
                  dimension: 9,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.4,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SwipeToReply extends StatefulWidget {
  const _SwipeToReply({
    required this.enabled,
    required this.child,
    this.onReply,
  });

  final bool enabled;
  final Widget child;
  final VoidCallback? onReply;

  @override
  State<_SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<_SwipeToReply> {
  static const _threshold = 52.0;
  double _offset = 0;
  bool _announced = false;

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragUpdate: (details) {
        final next = (_offset + details.delta.dx).clamp(0.0, 72.0);
        if (!_announced && next >= _threshold) {
          _announced = true;
          HapticFeedback.selectionClick();
        } else if (_announced && next < _threshold) {
          _announced = false;
        }
        setState(() => _offset = next);
      },
      onHorizontalDragEnd: (_) {
        final shouldReply = _offset >= _threshold;
        setState(() {
          _offset = 0;
          _announced = false;
        });
        if (shouldReply) widget.onReply?.call();
      },
      onHorizontalDragCancel: () => setState(() {
        _offset = 0;
        _announced = false;
      }),
      child: Stack(
        alignment: Alignment.centerLeft,
        children: [
          if (_offset > 8)
            Positioned(
              left: 12,
              child: Opacity(
                opacity: (_offset / _threshold).clamp(0, 1),
                child: Icon(
                  Icons.reply_rounded,
                  size: AppIconSize.md,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
          AnimatedContainer(
            duration: _offset == 0
                ? const Duration(milliseconds: 170)
                : Duration.zero,
            curve: Curves.easeOutCubic,
            transform: Matrix4.translationValues(_offset, 0, 0),
            child: widget.child,
          ),
        ],
      ),
    );
  }
}

class _MessageAttachmentView extends ConsumerStatefulWidget {
  const _MessageAttachmentView({
    required this.attachment,
    required this.foreground,
    required this.sendFailed,
    super.key,
  });

  final MessageAttachment attachment;
  final Color foreground;
  final bool sendFailed;

  @override
  ConsumerState<_MessageAttachmentView> createState() =>
      _MessageAttachmentViewState();
}

class _MessageAttachmentViewState
    extends ConsumerState<_MessageAttachmentView> {
  Future<MessageAttachmentContent>? _content;
  MessageAttachmentContent? _initialContent;
  bool _saving = false;

  bool get _isImage => widget.attachment.contentType.startsWith('image/');

  @override
  void initState() {
    super.initState();
    if (_isImage && widget.attachment.downloadUri != null) {
      final controller = ref.read(messagesControllerProvider.notifier);
      _initialContent = controller.cachedAttachment(widget.attachment);
      _content = _initialContent == null
          ? controller.loadAttachment(widget.attachment)
          : null;
    }
  }

  @override
  void didUpdateWidget(covariant _MessageAttachmentView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.attachment.downloadUri != widget.attachment.downloadUri ||
        oldWidget.attachment.contentType != widget.attachment.contentType) {
      _content = _isImage && widget.attachment.downloadUri != null
          ? ref
                .read(messagesControllerProvider.notifier)
                .loadAttachment(widget.attachment)
          : null;
      _initialContent = _isImage
          ? ref
                .read(messagesControllerProvider.notifier)
                .cachedAttachment(widget.attachment)
          : null;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.attachment.downloadUri == null) {
      return _AttachmentPlaceholder(
        label: widget.sendFailed
            ? 'Attachment was not sent'
            : switch (widget.attachment.state) {
                MessageAttachmentState.rejected =>
                  'Media could not be processed',
                MessageAttachmentState.expired => 'Media has expired',
                _ => 'Media is being processed',
              },
        foreground: widget.foreground,
      );
    }
    if (!_isImage) {
      return _AttachmentDownloadButton(
        attachment: widget.attachment,
        foreground: widget.foreground,
        saving: _saving,
        onPressed: _openFileViewer,
      );
    }
    return FutureBuilder<MessageAttachmentContent>(
      future: _content,
      initialData: _initialContent,
      builder: (context, snapshot) {
        final content = snapshot.data;
        if (content == null &&
            snapshot.connectionState != ConnectionState.done) {
          return SizedBox(
            width: 180,
            height: 120,
            child: Center(
              child: CircularProgressIndicator(color: widget.foreground),
            ),
          );
        }
        if (snapshot.hasError || content == null) {
          return _AttachmentPlaceholder(
            label: 'Media could not be loaded',
            foreground: widget.foreground,
            onRetry: _retryLoad,
          );
        }
        return Semantics(
          button: true,
          label: 'Open ${_fileName(widget.attachment)}',
          child: InkWell(
            onTap: () => _openViewer(content),
            borderRadius: BorderRadius.circular(10),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  minWidth: 120,
                  maxWidth: 280,
                  maxHeight: 280,
                ),
                child: Image.memory(
                  content.bytes,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                  cacheWidth: 1120,
                  filterQuality: FilterQuality.medium,
                  errorBuilder: (_, _, _) => _AttachmentPlaceholder(
                    label: 'Image could not be displayed',
                    foreground: widget.foreground,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _retryLoad() {
    setState(() {
      _initialContent = null;
      _content = ref
          .read(messagesControllerProvider.notifier)
          .loadAttachment(widget.attachment);
    });
  }

  Future<void> _openViewer(MessageAttachmentContent content) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => _AttachmentViewerScreen(
          attachment: widget.attachment,
          content: content,
          onSave: () => _save(content),
        ),
      ),
    );
  }

  Future<void> _openFileViewer() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final content = await ref
          .read(messagesControllerProvider.notifier)
          .loadAttachment(widget.attachment);
      if (!mounted) return;
      await _openViewer(content);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Attachment could not be opened.')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _save([MessageAttachmentContent? existing]) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final content =
          existing ??
          await ref
              .read(messagesControllerProvider.notifier)
              .loadAttachment(widget.attachment);
      final location = await AppFiles().saveBytes(
        fileName: _fileName(widget.attachment),
        bytes: content.bytes,
        mimeType: content.contentType,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Saved to $location')));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Attachment could not be saved.')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

class _AttachmentViewerScreen extends StatelessWidget {
  const _AttachmentViewerScreen({
    required this.attachment,
    required this.content,
    required this.onSave,
  });

  final MessageAttachment attachment;
  final MessageAttachmentContent content;
  final Future<void> Function() onSave;

  @override
  Widget build(BuildContext context) {
    final isImage = content.contentType.startsWith('image/');
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          _fileName(attachment),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: 'Save attachment',
            onPressed: onSave,
            icon: const Icon(AppIcons.importFile),
          ),
        ],
      ),
      body: SafeArea(
        child: isImage
            ? Center(
                child: InteractiveViewer(
                  minScale: 0.5,
                  maxScale: 5,
                  child: Image.memory(
                    content.bytes,
                    fit: BoxFit.contain,
                    semanticLabel: _fileName(attachment),
                  ),
                ),
              )
            : Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        AppIcons.importFile,
                        color: Colors.white,
                        size: 56,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        _fileName(attachment),
                        textAlign: TextAlign.center,
                        style: Theme.of(
                          context,
                        ).textTheme.titleMedium?.copyWith(color: Colors.white),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${content.contentType} · ${_fileSize(content.bytes.length)}',
                        style: const TextStyle(color: Colors.white70),
                      ),
                      const SizedBox(height: 20),
                      FilledButton.icon(
                        onPressed: onSave,
                        icon: const Icon(AppIcons.importFile),
                        label: const Text('Save file'),
                      ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }
}

class _AttachmentPlaceholder extends StatelessWidget {
  const _AttachmentPlaceholder({
    required this.label,
    required this.foreground,
    this.onRetry,
  });

  final String label;
  final Color foreground;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 180,
      height: 96,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            onRetry == null ? Icons.image_not_supported_outlined : Icons.image,
            color: foreground,
          ),
          const SizedBox(height: 8),
          Text(label, style: TextStyle(color: foreground)),
          if (onRetry != null) ...[
            const SizedBox(height: 4),
            TextButton.icon(
              onPressed: onRetry,
              style: TextButton.styleFrom(foregroundColor: foreground),
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Try again'),
            ),
          ],
        ],
      ),
    );
  }
}

class _AttachmentDownloadButton extends StatelessWidget {
  const _AttachmentDownloadButton({
    required this.attachment,
    required this.foreground,
    required this.saving,
    required this.onPressed,
  });

  final MessageAttachment attachment;
  final Color foreground;
  final bool saving;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: saving ? null : onPressed,
      icon: saving
          ? SizedBox.square(
              dimension: AppIconSize.sm,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: foreground,
              ),
            )
          : Icon(AppIcons.importFile, color: foreground),
      label: Text(
        _fileName(attachment),
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: foreground),
      ),
    );
  }
}

String _fileName(MessageAttachment attachment) {
  final supplied = attachment.fileName?.trim();
  if (supplied?.isNotEmpty == true) return supplied!;
  final extension = switch (attachment.contentType) {
    'image/jpeg' => 'jpg',
    'image/png' => 'png',
    'image/gif' => 'gif',
    'image/webp' => 'webp',
    'application/pdf' => 'pdf',
    'audio/mpeg' => 'mp3',
    'video/mp4' => 'mp4',
    _ => 'bin',
  };
  return 'attachment-${attachment.id}.$extension';
}

String _fileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

bool _sameDay(DateTime a, DateTime b) {
  final left = a.toLocal();
  final right = b.toLocal();
  return left.year == right.year &&
      left.month == right.month &&
      left.day == right.day;
}

String _dayLabel(DateTime value) {
  final local = value.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  final delta = today.difference(day).inDays;
  if (delta == 0) {
    return 'Today';
  }
  if (delta == 1) {
    return 'Yesterday';
  }
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  if (local.year == now.year) {
    return '${months[local.month - 1]} ${local.day}';
  }
  return '${months[local.month - 1]} ${local.day}, ${local.year}';
}

String _timeLabel(DateTime value) {
  final local = value.toLocal();
  final hour24 = local.hour;
  final minute = local.minute.toString().padLeft(2, '0');
  final period = hour24 >= 12 ? 'PM' : 'AM';
  final hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12;
  return '$hour12:$minute $period';
}

class _MessageMeta extends StatelessWidget {
  const _MessageMeta({required this.message, required this.foreground});

  final CarrierMessage message;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    final time = _timeLabel(message.createdAt);
    final status = message.direction == MessageDirection.incoming
        ? null
        : _statusPresentation(message);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          time,
          style: Theme.of(
            context,
          ).textTheme.labelSmall?.copyWith(color: foreground, letterSpacing: 0),
        ),
        if (status case final value?) ...[
          const SizedBox(width: 4),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: ScaleTransition(scale: animation, child: child),
            ),
            child: Tooltip(
              key: ValueKey(message.status),
              message: value.label,
              child: Semantics(
                label: value.label,
                child: Icon(value.icon, size: 14, color: foreground),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

({IconData icon, String label})? _statusPresentation(CarrierMessage message) {
  return switch (message.status) {
    MessageStatus.received => null,
    MessageStatus.queued => (
      icon: Icons.hourglass_empty_rounded,
      label: 'Queued',
    ),
    MessageStatus.sending => (icon: Icons.send_rounded, label: 'Sending'),
    MessageStatus.submitted => (icon: Icons.check, label: 'Submitted'),
    MessageStatus.sent => (icon: Icons.check, label: 'Sent'),
    MessageStatus.delivered => (icon: Icons.done_all, label: 'Delivered'),
    MessageStatus.undelivered => (
      icon: Icons.error_outline,
      label: 'Undelivered',
    ),
    MessageStatus.failed when message.errorCode == 'submission_uncertain' => (
      icon: Icons.help_outline,
      label: 'Delivery unconfirmed',
    ),
    MessageStatus.failed => (icon: Icons.error_outline, label: 'Failed'),
  };
}

enum _ThreadAction { addContact, block, unblock }

enum _MessageAction { reply, copy, delete }
