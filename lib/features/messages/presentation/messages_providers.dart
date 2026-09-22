import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../session/presentation/session_controller.dart';
import '../data/messaging_providers.dart';
import '../domain/carrier_message.dart';
import '../domain/carrier_messaging_config.dart';
import '../domain/messaging_platform.dart';
import '../domain/messaging_repository.dart';
import '../domain/sms_compatibility.dart';
import '../domain/sms_segment_info.dart';
import 'initial_inbox_reconciler.dart';
import 'refreshed_conversation_reconciler.dart';

final messagesControllerProvider =
    NotifierProvider<MessagesController, MessagesState>(MessagesController.new);

enum MessagingAvailability {
  unsupportedPlatform,
  notProvisioned,
  suspended,
  incompleteProvisioning,
  integrationPending,
  ready,
}

class MessagesState {
  const MessagesState({
    this.threads = const {},
    this.availability = MessagingAvailability.notProvisioned,
    this.config,
    this.unreadByRemoteNumber = const {},
    this.blocksByRemoteNumber = const {},
    this.transportCanSend = false,
    this.transportCanSendMms = false,
    this.maxOutboundSmsSegments = 10,
    this.outboundSmsUsesIndependentParts = false,
    this.maxOutboundAttachmentBytes = 1000000,
    this.outboundAttachmentMimeTypes = const {'image/jpeg'},
    this.nextConversationCursor,
    this.threadNextCursors = const {},
    this.isLoadingMoreConversations = false,
    this.loadingOlderThreads = const {},
    this.isLoading = false,
    this.errorMessage,
  });

  final Map<String, List<CarrierMessage>> threads;
  final MessagingAvailability availability;
  final CarrierMessagingConfig? config;
  final Map<String, int> unreadByRemoteNumber;
  final Map<String, MessagingBlock> blocksByRemoteNumber;
  final bool transportCanSend;
  final bool transportCanSendMms;
  final int maxOutboundSmsSegments;
  final bool outboundSmsUsesIndependentParts;
  final int maxOutboundAttachmentBytes;
  final Set<String> outboundAttachmentMimeTypes;
  final String? nextConversationCursor;
  final Map<String, String> threadNextCursors;
  final bool isLoadingMoreConversations;
  final Set<String> loadingOlderThreads;
  final bool isLoading;
  final String? errorMessage;

  bool get canSend =>
      availability == MessagingAvailability.ready && transportCanSend;

  bool get canSendMms => canSend && transportCanSendMms;

  bool isBlocked(String remoteNumber) =>
      blocksByRemoteNumber.containsKey(remoteNumber);

  MessagesState copyWith({
    Map<String, List<CarrierMessage>>? threads,
    MessagingAvailability? availability,
    CarrierMessagingConfig? config,
    Map<String, int>? unreadByRemoteNumber,
    Map<String, MessagingBlock>? blocksByRemoteNumber,
    bool? transportCanSend,
    bool? transportCanSendMms,
    int? maxOutboundSmsSegments,
    bool? outboundSmsUsesIndependentParts,
    int? maxOutboundAttachmentBytes,
    Set<String>? outboundAttachmentMimeTypes,
    String? nextConversationCursor,
    bool clearConversationCursor = false,
    Map<String, String>? threadNextCursors,
    bool? isLoadingMoreConversations,
    Set<String>? loadingOlderThreads,
    bool? isLoading,
    String? errorMessage,
    bool clearError = false,
  }) {
    return MessagesState(
      threads: threads ?? this.threads,
      availability: availability ?? this.availability,
      config: config ?? this.config,
      unreadByRemoteNumber: unreadByRemoteNumber ?? this.unreadByRemoteNumber,
      blocksByRemoteNumber: blocksByRemoteNumber ?? this.blocksByRemoteNumber,
      transportCanSend: transportCanSend ?? this.transportCanSend,
      transportCanSendMms: transportCanSendMms ?? this.transportCanSendMms,
      maxOutboundSmsSegments:
          maxOutboundSmsSegments ?? this.maxOutboundSmsSegments,
      outboundSmsUsesIndependentParts:
          outboundSmsUsesIndependentParts ??
          this.outboundSmsUsesIndependentParts,
      maxOutboundAttachmentBytes:
          maxOutboundAttachmentBytes ?? this.maxOutboundAttachmentBytes,
      outboundAttachmentMimeTypes:
          outboundAttachmentMimeTypes ?? this.outboundAttachmentMimeTypes,
      nextConversationCursor: clearConversationCursor
          ? null
          : nextConversationCursor ?? this.nextConversationCursor,
      threadNextCursors: threadNextCursors ?? this.threadNextCursors,
      isLoadingMoreConversations:
          isLoadingMoreConversations ?? this.isLoadingMoreConversations,
      loadingOlderThreads: loadingOlderThreads ?? this.loadingOlderThreads,
      isLoading: isLoading ?? this.isLoading,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
    );
  }
}

class MessagesController extends Notifier<MessagesState> {
  StreamSubscription<CarrierMessage>? _subscription;
  StreamSubscription<void>? _inboxSubscription;
  Future<void>? _discovery;
  Future<void>? _connection;
  Future<void>? _inboxRefresh;
  int? _connectionGeneration;
  MessagingRepository? _connectedRepository;
  String? _connectedInboxId;
  final Set<String> _loadingThreads = {};
  final Set<String> _loadedThreads = {};
  final Map<String, DateTime> _readOverrides = {};
  final Map<String, DateTime> _deletedConversationOverrides = {};
  final Map<String, MessageAttachmentContent> _attachmentContent = {};
  final Map<String, Future<MessageAttachmentContent>> _attachmentLoads = {};
  int _sessionGeneration = 0;
  bool _hasSessionBoundary = false;
  String? _activeSessionBoundary;

  @override
  MessagesState build() {
    ref.onDispose(() {
      unawaited(_subscription?.cancel());
      unawaited(_inboxSubscription?.cancel());
    });
    final appSession = ref.watch(sessionControllerProvider).value;
    final config = appSession?.carrierMessaging;
    final boundary = appSession == null
        ? null
        : '${appSession.user.id}\u0000${appSession.device.deviceId ?? ''}\u0000${config?.inboxId ?? ''}';
    if (!_hasSessionBoundary || boundary != _activeSessionBoundary) {
      _resetSessionBoundary(boundary);
    }
    final generation = ++_sessionGeneration;
    final repository = ref.watch(messagingRepositoryProvider);
    final hasBootstrapCredential =
        appSession?.deviceCredential != null ||
        appSession?.directoryAccess != null;
    final availability =
        config?.readiness == CarrierMessagingReadiness.ready &&
            !hasBootstrapCredential
        ? MessagingAvailability.incompleteProvisioning
        : _availability(config, repository);
    if (availability == MessagingAvailability.ready) {
      Future<void>.microtask(
        () => _connect(config!, repository, generation: generation),
      );
    } else if (config == null &&
        hasBootstrapCredential &&
        repository.isConfigured) {
      Future<void>.microtask(
        () => _discoverConfig(repository, generation: generation),
      );
    } else if (appSession != null && repository.isConfigured) {
      Future<void>.microtask(repository.clearLocalData);
    }
    return MessagesState(
      config: config,
      availability:
          config == null && hasBootstrapCredential && repository.isConfigured
          ? MessagingAvailability.integrationPending
          : availability,
      transportCanSend: repository.canSend,
      transportCanSendMms: repository.canSendMms,
      maxOutboundSmsSegments: repository.maxOutboundSmsSegments,
      outboundSmsUsesIndependentParts:
          repository.outboundSmsUsesIndependentParts,
      maxOutboundAttachmentBytes: repository.maxOutboundAttachmentBytes,
      outboundAttachmentMimeTypes: repository.outboundAttachmentMimeTypes,
    );
  }

  Future<void> _discoverConfig(
    MessagingRepository repository, {
    required int generation,
  }) {
    final pending = _discovery;
    if (pending != null) return pending;
    final future = _performDiscovery(repository, generation: generation);
    _discovery = future;
    return future.whenComplete(() {
      if (identical(_discovery, future)) _discovery = null;
    });
  }

  Future<void> _performDiscovery(
    MessagingRepository repository, {
    required int generation,
  }) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final config = await repository.discoverConfig();
      if (generation != _sessionGeneration) return;
      if (config == null) {
        state = state.copyWith(
          availability: MessagingAvailability.notProvisioned,
          isLoading: false,
        );
        return;
      }
      await ref
          .read(sessionControllerProvider.notifier)
          .setCarrierMessagingConfig(config);
      if (generation != _sessionGeneration &&
          state.config?.inboxId != config.inboxId) {
        return;
      }
      state = state.copyWith(
        config: config,
        availability: _availability(config, repository),
        isLoading: false,
      );
      await _connect(config, repository, generation: _sessionGeneration);
    } catch (_) {
      if (generation != _sessionGeneration) return;
      state = state.copyWith(
        availability: MessagingAvailability.integrationPending,
        isLoading: false,
        errorMessage: 'Messaging assignment could not be synchronized.',
      );
    }
  }

  List<CarrierMessage> messagesFor(String remoteNumber) {
    return state.threads[remoteNumber] ?? const [];
  }

  Future<String?> remoteNumberForMessage(String messageId) async {
    final config = state.config;
    if (config == null || state.availability != MessagingAvailability.ready) {
      return null;
    }
    try {
      final message = await ref
          .read(messagingRepositoryProvider)
          .loadMessage(config: config, messageId: messageId);
      if (message == null || message.remoteNumber.isEmpty) return null;
      recordMessage(message);
      return message.remoteNumber;
    } catch (_) {
      state = state.copyWith(
        errorMessage: 'The selected message could not be opened.',
      );
      return null;
    }
  }

  Future<MessageAttachmentContent> loadAttachment(
    MessageAttachment attachment,
  ) {
    final config = state.config;
    if (config == null || state.availability != MessagingAvailability.ready) {
      throw const MessagingIntegrationUnavailable();
    }
    final key = _attachmentKey(attachment);
    final cached = _attachmentContent[key];
    if (cached != null) return Future.value(cached);
    final pending = _attachmentLoads[key];
    if (pending != null) return pending;
    late final Future<MessageAttachmentContent> load;
    load = ref
        .read(messagingRepositoryProvider)
        .loadAttachment(config: config, attachment: attachment)
        .then((content) {
          _attachmentContent[key] = content;
          return content;
        })
        .whenComplete(() {
          if (identical(_attachmentLoads[key], load)) {
            _attachmentLoads.remove(key);
          }
        });
    _attachmentLoads[key] = load;
    return load;
  }

  MessageAttachmentContent? cachedAttachment(MessageAttachment attachment) =>
      _attachmentContent[_attachmentKey(attachment)];

  void ensureThread(String remoteNumber) {
    if (!state.threads.containsKey(remoteNumber)) {
      state = state.copyWith(
        threads: {...state.threads, remoteNumber: const []},
      );
    }
    if (!_loadedThreads.contains(remoteNumber)) {
      unawaited(_loadThread(remoteNumber));
    }
  }

  Future<void> loadOlderMessages(String remoteNumber) async {
    final cursor = state.threadNextCursors[remoteNumber];
    if (cursor == null) return;
    await _loadThread(remoteNumber, cursor: cursor);
  }

  Future<void> refreshConversation(String remoteNumber) async {
    final config = state.config;
    final generation = _sessionGeneration;
    if (config == null ||
        state.availability != MessagingAvailability.ready ||
        !_loadingThreads.add(remoteNumber)) {
      return;
    }
    try {
      final page = await ref
          .read(messagingRepositoryProvider)
          .loadConversation(config: config, remoteNumber: remoteNumber);
      if (generation != _sessionGeneration ||
          state.config?.inboxId != config.inboxId) {
        return;
      }
      final messages = reconcileRefreshedConversation(
        existing: state.threads[remoteNumber] ?? const [],
        authoritative: page.messages,
      );
      final cursors = {...state.threadNextCursors};
      if (page.nextCursor == null) {
        cursors.remove(remoteNumber);
      } else {
        cursors[remoteNumber] = page.nextCursor!;
      }
      _loadedThreads.add(remoteNumber);
      state = state.copyWith(
        threads: {...state.threads, remoteNumber: messages},
        threadNextCursors: cursors,
        clearError: true,
      );
    } catch (_) {
      if (generation != _sessionGeneration) return;
      state = state.copyWith(
        errorMessage: 'Conversation history could not be refreshed.',
      );
    } finally {
      if (generation == _sessionGeneration) {
        _loadingThreads.remove(remoteNumber);
      }
    }
  }

  Future<void> loadMoreConversations() async {
    final config = state.config;
    final generation = _sessionGeneration;
    final cursor = state.nextConversationCursor;
    if (config == null || cursor == null || state.isLoadingMoreConversations) {
      return;
    }
    state = state.copyWith(isLoadingMoreConversations: true);
    try {
      final inbox = await ref
          .read(messagingRepositoryProvider)
          .loadInbox(config: config, cursor: cursor);
      if (generation != _sessionGeneration ||
          state.config?.inboxId != config.inboxId) {
        return;
      }
      final threads = {...state.threads};
      for (final remote in [
        ...inbox.remoteNumbers,
        ...inbox.blocksByRemoteNumber.keys,
      ]) {
        threads.putIfAbsent(remote, () => const []);
      }
      state = state.copyWith(
        threads: threads,
        unreadByRemoteNumber: {
          ...state.unreadByRemoteNumber,
          ...inbox.unreadByRemoteNumber,
        },
        blocksByRemoteNumber: {
          ...state.blocksByRemoteNumber,
          ...inbox.blocksByRemoteNumber,
        },
        nextConversationCursor: inbox.nextCursor,
        clearConversationCursor: inbox.nextCursor == null,
        isLoadingMoreConversations: false,
      );
      for (final message in inbox.messages) {
        recordMessage(message);
      }
    } catch (_) {
      if (generation != _sessionGeneration) return;
      state = state.copyWith(
        isLoadingMoreConversations: false,
        errorMessage: 'More conversations could not be loaded.',
      );
    }
  }

  void recordMessage(CarrierMessage message) {
    if (!_acceptMessageForDeletionBoundary(message)) return;
    if (message.direction == MessageDirection.incoming) {
      final readAt = _readOverrides[message.remoteNumber];
      if (readAt != null && message.createdAt.toUtc().isAfter(readAt)) {
        _readOverrides.remove(message.remoteNumber);
      }
    }
    final threads = {
      for (final entry in state.threads.entries) entry.key: [...entry.value],
    };
    final thread = threads.putIfAbsent(message.remoteNumber, () => []);
    if (message.id.isNotEmpty) {
      thread.removeWhere((item) => item.id == message.id);
    }
    final clientId = message.clientId;
    if (clientId != null) {
      thread.removeWhere((item) => item.clientId == clientId);
    }
    thread.add(message);
    thread.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    state = state.copyWith(threads: threads, clearError: true);
  }

  Future<void> sendMessage({
    required String destination,
    required String text,
    OutboundMessageAttachment? attachment,
    String? clientId,
    void Function(int sent, int total)? onSendProgress,
  }) async {
    final config = state.config;
    final normalizedDestination = destinationForRaw(destination);
    final trimmed = smartEncodeSmsText(expandSmsEmojiShortcodes(text.trim()));
    if (!state.canSend || config == null) {
      throw const MessagingIntegrationUnavailable();
    }
    if (state.isBlocked(normalizedDestination)) {
      throw const MessagingOutboundUnavailable();
    }
    if (attachment != null && !state.canSendMms) {
      throw const MessagingOutboundUnavailable();
    }
    if (normalizedDestination.isEmpty ||
        (trimmed.isEmpty && attachment == null)) {
      throw const FormatException('A valid public phone number is required.');
    }
    if (attachment == null) {
      final segments = state.outboundSmsUsesIndependentParts
          ? analyzeIndependentSmsParts(trimmed)
          : analyzeSmsSegments(trimmed);
      if (!segments.fitsWithin(state.maxOutboundSmsSegments)) {
        throw MessagingSmsSegmentLimitExceeded(
          actualSegments: segments.segmentCount,
          maximumSegments: state.maxOutboundSmsSegments,
        );
      }
    }

    final effectiveClientId =
        clientId ?? 'app-${DateTime.now().microsecondsSinceEpoch}';
    final pending = CarrierMessage(
      id: effectiveClientId,
      clientId: effectiveClientId,
      remoteNumber: normalizedDestination,
      direction: MessageDirection.outgoing,
      text: trimmed,
      status: MessageStatus.sending,
      createdAt: DateTime.now(),
      attachments: attachment == null
          ? const []
          : [
              MessageAttachment(
                id: '$effectiveClientId-attachment',
                contentType: attachment.contentType,
                fileName: attachment.fileName,
                sizeBytes: attachment.bytes.length,
                state: MessageAttachmentState.pending,
              ),
            ],
    );
    recordMessage(pending);
    try {
      final sent = await ref
          .read(messagingRepositoryProvider)
          .sendMessage(
            config: config,
            destination: normalizedDestination,
            text: trimmed,
            clientId: effectiveClientId,
            attachment: attachment,
            onSendProgress: onSendProgress,
          );
      recordMessage(sent);
    } catch (_) {
      if (attachment == null) {
        recordMessage(
          CarrierMessage(
            id: '$effectiveClientId-failed',
            clientId: effectiveClientId,
            remoteNumber: normalizedDestination,
            direction: MessageDirection.outgoing,
            text: trimmed,
            status: MessageStatus.failed,
            createdAt: pending.createdAt,
          ),
        );
      } else {
        final threads = {
          for (final entry in state.threads.entries)
            entry.key: [...entry.value],
        };
        threads[normalizedDestination]?.removeWhere(
          (item) => item.clientId == effectiveClientId,
        );
        state = state.copyWith(threads: threads);
      }
      rethrow;
    }
  }

  Future<void> retryMessage(CarrierMessage message) async {
    if (!message.canRetry) {
      throw const FormatException('This message cannot be safely retried.');
    }
    final config = state.config;
    if (config == null || state.availability != MessagingAvailability.ready) {
      throw const MessagingIntegrationUnavailable();
    }
    final originalClientId = message.clientId;
    final localFailure =
        originalClientId != null && message.id == '$originalClientId-failed';
    if (localFailure) {
      await sendMessage(
        destination: message.remoteNumber,
        text: message.text,
        clientId: originalClientId,
      );
      return;
    }

    recordMessage(
      CarrierMessage(
        id: message.id,
        clientId: message.clientId,
        errorCode: message.errorCode,
        remoteNumber: message.remoteNumber,
        direction: message.direction,
        text: message.text,
        status: MessageStatus.sending,
        createdAt: message.createdAt,
        attachments: message.attachments,
      ),
    );
    try {
      final retried = await ref
          .read(messagingRepositoryProvider)
          .retryMessage(config: config, messageId: message.id);
      recordMessage(retried);
    } catch (_) {
      recordMessage(message);
      rethrow;
    }
  }

  Future<void> markConversationRead(String remoteNumber) async {
    final config = state.config;
    if (config == null || state.availability != MessagingAvailability.ready) {
      return;
    }
    final previousUnread = state.unreadByRemoteNumber[remoteNumber] ?? 0;
    _readOverrides[remoteNumber] = DateTime.now().toUtc();
    final unread = {...state.unreadByRemoteNumber, remoteNumber: 0};
    state = state.copyWith(unreadByRemoteNumber: unread);
    try {
      await ref
          .read(messagingRepositoryProvider)
          .markConversationRead(config: config, remoteNumber: remoteNumber);
    } catch (_) {
      _readOverrides.remove(remoteNumber);
      state = state.copyWith(
        unreadByRemoteNumber: {
          ...state.unreadByRemoteNumber,
          remoteNumber: previousUnread,
        },
        errorMessage: 'Read status could not be synchronized.',
      );
    }
  }

  Future<void> deleteConversation(String remoteNumber) async {
    final config = state.config;
    final normalized = destinationForRaw(remoteNumber);
    if (config == null || normalized.isEmpty) {
      throw const MessagingIntegrationUnavailable();
    }
    await ref
        .read(messagingRepositoryProvider)
        .deleteConversation(config: config, remoteNumber: normalized);
    _clearAttachmentMemory();
    final deletedAt = DateTime.now().toUtc();
    _deletedConversationOverrides[normalized] = deletedAt;
    try {
      await ref
          .read(messagingDeletionStoreProvider)
          .mark(
            inboxId: config.inboxId,
            remoteNumber: normalized,
            deletedAt: deletedAt,
          );
    } catch (_) {
      // The successful server deletion and in-memory marker remain effective.
    }
    _readOverrides.remove(normalized);
    final threads = {...state.threads}..remove(normalized);
    final unread = {...state.unreadByRemoteNumber}..remove(normalized);
    final cursors = {...state.threadNextCursors}..remove(normalized);
    _loadedThreads.remove(normalized);
    state = state.copyWith(
      threads: threads,
      unreadByRemoteNumber: unread,
      threadNextCursors: cursors,
      clearError: true,
    );
  }

  Future<void> deleteMessage(CarrierMessage message) async {
    final config = state.config;
    if (config == null || message.id.isEmpty) {
      throw const MessagingIntegrationUnavailable();
    }
    await ref
        .read(messagingRepositoryProvider)
        .deleteMessage(config: config, messageId: message.id);
    _clearAttachmentMemory();
    final threads = {
      for (final entry in state.threads.entries) entry.key: [...entry.value],
    };
    threads[message.remoteNumber]?.removeWhere((item) => item.id == message.id);
    state = state.copyWith(threads: threads, clearError: true);
  }

  Future<void> blockNumber(
    String remoteNumber, {
    bool reportSpam = false,
  }) async {
    final config = state.config;
    final normalized = destinationForRaw(remoteNumber);
    if (config == null || normalized.isEmpty) {
      throw const FormatException('A valid public phone number is required.');
    }
    final block = await ref
        .read(messagingRepositoryProvider)
        .blockNumber(
          config: config,
          remoteNumber: normalized,
          reason: reportSpam ? 'spam_report' : 'user_blocked',
        );
    state = state.copyWith(
      blocksByRemoteNumber: {...state.blocksByRemoteNumber, normalized: block},
      clearError: true,
    );
  }

  Future<void> unblockNumber(String remoteNumber) async {
    final config = state.config;
    final normalized = destinationForRaw(remoteNumber);
    final block = state.blocksByRemoteNumber[normalized];
    if (config == null || block == null) return;
    await ref
        .read(messagingRepositoryProvider)
        .unblockNumber(config: config, blockId: block.id);
    final blocks = {...state.blocksByRemoteNumber}..remove(normalized);
    state = state.copyWith(blocksByRemoteNumber: blocks, clearError: true);
  }

  Future<void> refresh() async {
    final config = state.config;
    if (config == null || state.availability != MessagingAvailability.ready) {
      return;
    }
    await _connect(config, ref.read(messagingRepositoryProvider));
  }

  String destinationForRaw(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return '';
    final digits = text.replaceAll(RegExp(r'[^0-9]'), '');
    if (text.startsWith('+') && digits.length >= 8 && digits.length <= 15) {
      return '+$digits';
    }
    if (digits.length == 10) return '+1$digits';
    if (digits.length == 11 && digits.startsWith('1')) return '+$digits';
    return '';
  }

  Future<void> _connect(
    CarrierMessagingConfig config,
    MessagingRepository repository, {
    int? generation,
    bool showLoading = true,
  }) {
    final effectiveGeneration = generation ?? _sessionGeneration;
    final pending = _connection;
    if (pending != null && _connectionGeneration == effectiveGeneration) {
      return pending;
    }
    final future = _performConnect(
      config,
      repository,
      generation: effectiveGeneration,
      showLoading: showLoading,
    );
    _connection = future;
    _connectionGeneration = effectiveGeneration;
    return future.whenComplete(() {
      if (identical(_connection, future)) {
        _connection = null;
        _connectionGeneration = null;
      }
    });
  }

  Future<void> _performConnect(
    CarrierMessagingConfig config,
    MessagingRepository repository, {
    required int generation,
    required bool showLoading,
  }) async {
    if (showLoading) {
      state = state.copyWith(isLoading: true, clearError: true);
    }
    try {
      final persistedDeletions = await ref
          .read(messagingDeletionStoreProvider)
          .read(config.inboxId);
      if (generation != _sessionGeneration ||
          state.config?.inboxId != config.inboxId) {
        return;
      }
      _deletedConversationOverrides
        ..clear()
        ..addAll(persistedDeletions);
      final inbox = await repository.loadInbox(config: config);
      if (generation != _sessionGeneration ||
          state.config?.inboxId != config.inboxId) {
        return;
      }
      final reconciliation = reconcileInitialInbox(
        existingThreads: state.threads,
        inbox: inbox,
        readOverrides: _readOverrides.keys.toSet(),
        deletedOverrides: _deletedConversationOverrides.keys.toSet(),
      );
      _readOverrides.removeWhere(
        (remote, _) => (inbox.unreadByRemoteNumber[remote] ?? 0) == 0,
      );
      state = state.copyWith(
        threads: reconciliation.threads,
        unreadByRemoteNumber: reconciliation.unreadByRemoteNumber,
        blocksByRemoteNumber: inbox.blocksByRemoteNumber,
        transportCanSend: repository.canSend,
        transportCanSendMms: repository.canSendMms,
        maxOutboundSmsSegments: repository.maxOutboundSmsSegments,
        outboundSmsUsesIndependentParts:
            repository.outboundSmsUsesIndependentParts,
        maxOutboundAttachmentBytes: repository.maxOutboundAttachmentBytes,
        outboundAttachmentMimeTypes: repository.outboundAttachmentMimeTypes,
        nextConversationCursor: inbox.nextCursor,
        clearConversationCursor: inbox.nextCursor == null,
      );
      for (final message in inbox.messages) {
        recordMessage(message);
      }
      final needsSubscription =
          _subscription == null ||
          !identical(_connectedRepository, repository) ||
          _connectedInboxId != config.inboxId;
      if (needsSubscription) {
        if (_connectedInboxId != config.inboxId) _clearAttachmentMemory();
        await _subscription?.cancel();
        await _inboxSubscription?.cancel();
        if (generation != _sessionGeneration ||
            state.config?.inboxId != config.inboxId) {
          return;
        }
        _inboxSubscription = repository
            .watchInboxInvalidations(config: config)
            .listen((_) {
              if (generation == _sessionGeneration &&
                  state.config?.inboxId == config.inboxId) {
                _requestAuthoritativeInboxRefresh(
                  config,
                  repository,
                  generation,
                );
              }
            }, onError: _recordStreamError);
        _subscription = repository.watchMessages(config: config).listen((
          message,
        ) {
          if (generation == _sessionGeneration &&
              state.config?.inboxId == config.inboxId) {
            // Unread counts come from the authoritative conversation index.
            // Replayed history and status changes must never be counted as new.
            recordMessage(message);
          }
        }, onError: _recordStreamError);
        _connectedRepository = repository;
        _connectedInboxId = config.inboxId;
      }
      state = state.copyWith(isLoading: false);
    } catch (_) {
      if (generation != _sessionGeneration ||
          state.config?.inboxId != config.inboxId) {
        return;
      }
      state = state.copyWith(
        isLoading: false,
        errorMessage: 'Messages could not be synchronized.',
      );
    }
  }

  void _recordStreamError(Object _) {
    state = state.copyWith(
      errorMessage: 'Realtime message updates are temporarily unavailable.',
    );
  }

  void _requestAuthoritativeInboxRefresh(
    CarrierMessagingConfig config,
    MessagingRepository repository,
    int generation,
  ) {
    if (_inboxRefresh != null) return;
    late final Future<void> refresh;
    refresh =
        Future<void>(() async {
          final connecting = _connection;
          if (connecting != null) await connecting;
          if (generation != _sessionGeneration ||
              state.config?.inboxId != config.inboxId) {
            return;
          }
          await _performConnect(
            config,
            repository,
            generation: generation,
            showLoading: false,
          );
        }).whenComplete(() {
          if (identical(_inboxRefresh, refresh)) _inboxRefresh = null;
        });
    _inboxRefresh = refresh;
  }

  String _attachmentKey(MessageAttachment attachment) =>
      '${attachment.id}\u0000${attachment.contentType}';

  void _clearAttachmentMemory() {
    _attachmentContent.clear();
    _attachmentLoads.clear();
  }

  Future<void> _loadThread(String remoteNumber, {String? cursor}) async {
    final config = state.config;
    final generation = _sessionGeneration;
    if (config == null ||
        state.availability != MessagingAvailability.ready ||
        !_loadingThreads.add(remoteNumber)) {
      return;
    }
    final loadingOlder = cursor != null;
    if (loadingOlder) {
      state = state.copyWith(
        loadingOlderThreads: {...state.loadingOlderThreads, remoteNumber},
      );
    }
    try {
      final page = await ref
          .read(messagingRepositoryProvider)
          .loadConversation(
            config: config,
            remoteNumber: remoteNumber,
            cursor: cursor,
          );
      if (generation != _sessionGeneration ||
          state.config?.inboxId != config.inboxId) {
        return;
      }
      for (final message in page.messages) {
        recordMessage(message);
      }
      _loadedThreads.add(remoteNumber);
      final cursors = {...state.threadNextCursors};
      if (page.nextCursor == null) {
        cursors.remove(remoteNumber);
      } else {
        cursors[remoteNumber] = page.nextCursor!;
      }
      final loading = {...state.loadingOlderThreads}..remove(remoteNumber);
      state = state.copyWith(
        threadNextCursors: cursors,
        loadingOlderThreads: loading,
      );
    } catch (_) {
      if (generation != _sessionGeneration) return;
      final loading = {...state.loadingOlderThreads}..remove(remoteNumber);
      state = state.copyWith(
        loadingOlderThreads: loading,
        errorMessage: 'Conversation history could not be synchronized.',
      );
    } finally {
      if (generation == _sessionGeneration) {
        _loadingThreads.remove(remoteNumber);
      }
    }
  }

  void _resetSessionBoundary(String? boundary) {
    _hasSessionBoundary = true;
    _activeSessionBoundary = boundary;
    _sessionGeneration++;
    final subscription = _subscription;
    _subscription = null;
    if (subscription != null) unawaited(subscription.cancel());
    final inboxSubscription = _inboxSubscription;
    _inboxSubscription = null;
    if (inboxSubscription != null) unawaited(inboxSubscription.cancel());
    _discovery = null;
    _connection = null;
    _inboxRefresh = null;
    _connectionGeneration = null;
    _connectedRepository = null;
    _connectedInboxId = null;
    _loadingThreads.clear();
    _loadedThreads.clear();
    _readOverrides.clear();
    _deletedConversationOverrides.clear();
    _clearAttachmentMemory();
  }

  bool _acceptMessageForDeletionBoundary(CarrierMessage message) {
    final deletedAt = _deletedConversationOverrides[message.remoteNumber];
    if (deletedAt == null) return true;
    if (!message.createdAt.toUtc().isAfter(deletedAt)) return false;
    _deletedConversationOverrides.remove(message.remoteNumber);
    final inboxId = state.config?.inboxId;
    if (inboxId != null) {
      unawaited(_removeDeletionMarker(inboxId, message.remoteNumber));
    }
    return true;
  }

  Future<void> _removeDeletionMarker(
    String inboxId,
    String remoteNumber,
  ) async {
    try {
      await ref
          .read(messagingDeletionStoreProvider)
          .remove(inboxId: inboxId, remoteNumber: remoteNumber);
    } catch (_) {
      // The marker will expire automatically if secure storage is unavailable.
    }
  }
}

MessagingAvailability _availability(
  CarrierMessagingConfig? config,
  MessagingRepository repository,
) {
  if (!isCarrierMessagingSupported()) {
    return MessagingAvailability.unsupportedPlatform;
  }
  return switch (config?.readiness) {
    null || CarrierMessagingReadiness.notAssigned =>
      MessagingAvailability.notProvisioned,
    CarrierMessagingReadiness.suspended => MessagingAvailability.suspended,
    CarrierMessagingReadiness.incomplete =>
      MessagingAvailability.incompleteProvisioning,
    CarrierMessagingReadiness.ready =>
      repository.isConfigured
          ? MessagingAvailability.ready
          : MessagingAvailability.integrationPending,
  };
}
