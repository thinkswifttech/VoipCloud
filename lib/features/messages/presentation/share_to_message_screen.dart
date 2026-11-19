import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../accounts/domain/account_line.dart';
import '../../accounts/presentation/accounts_controller.dart';
import '../../accounts/presentation/line_widgets.dart';
import '../../calls/presentation/caller_identity.dart';
import '../../contacts/presentation/contacts_providers.dart';
import '../../directory/presentation/directory_providers.dart';
import '../data/message_image_normalizer.dart';
import '../domain/messaging_repository.dart';
import 'messages_providers.dart';
import 'messaging_lines.dart';
import 'shared_content.dart';

/// Opened when another app (Photos, Amazon, Uber...) shares a link or photos
/// to VoipCloud: choose who gets it, then send it as a text or picture message.
class ShareToMessageScreen extends ConsumerStatefulWidget {
  const ShareToMessageScreen({super.key});

  @override
  ConsumerState<ShareToMessageScreen> createState() =>
      _ShareToMessageScreenState();
}

class _ShareToMessageScreenState extends ConsumerState<ShareToMessageScreen> {
  final _text = TextEditingController();
  final _number = TextEditingController();
  final _selected = <String>{};
  final _typed = <String>[];
  AccountLine? _line;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _text.text = ref.read(sharedContentProvider)?.text ?? '';
  }

  @override
  void dispose() {
    _text.dispose();
    _number.dispose();
    super.dispose();
  }

  void _snack(String message) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(message)));

  void _addTypedNumber(AccountLine line) {
    final number = ref
        .read(messagesControllerForLineProvider(line).notifier)
        .destinationForRaw(_number.text);
    if (number.isEmpty) {
      _snack('Enter a full phone number, for example 416 555 0123.');
      return;
    }
    setState(() {
      if (!_typed.contains(number)) _typed.add(number);
      _selected.add(number);
      _number.clear();
    });
  }

  Future<List<OutboundMessageAttachment>> _prepareAttachments(
    SharedContent content,
    MessagesState state,
  ) async {
    if (content.files.isEmpty) return const [];
    if (!state.canSendMms) {
      throw const FormatException('Photos cannot be sent from this account.');
    }
    final attachments = <OutboundMessageAttachment>[];
    for (final file in content.files) {
      if (!state.outboundAttachmentMimeTypes.contains(file.mimeType)) {
        throw const FormatException('This kind of file cannot be sent.');
      }
      final bytes = await normalizeMessageImage(
        bytes: await File(file.path).readAsBytes(),
        contentType: file.mimeType,
        maximumBytes: state.maxOutboundAttachmentBytes,
        stripMetadata: true,
      );
      if (bytes.length > state.maxOutboundAttachmentBytes) {
        throw const FormatException('This photo is too large to send.');
      }
      attachments.add(
        OutboundMessageAttachment(
          bytes: bytes,
          fileName: file.name.isEmpty ? 'photo.jpg' : file.name,
          contentType: file.mimeType,
        ),
      );
    }
    return attachments;
  }

  Future<void> _send(SharedContent content, AccountLine line) async {
    final state = ref.read(messagesControllerForLineProvider(line));
    final controller = ref.read(
      messagesControllerForLineProvider(line).notifier,
    );
    final sharedContent = ref.read(sharedContentProvider.notifier);
    final text = _text.text.trim();
    if (!state.canSend) {
      _snack('Messaging is not ready on this account yet.');
      return;
    }
    setState(() => _sending = true);
    final failed = <String>[];
    try {
      final attachments = await _prepareAttachments(content, state);
      for (final to in _selected.toList()) {
        try {
          if (attachments.isEmpty) {
            await controller.sendMessage(destination: to, text: text);
          }
          for (var i = 0; i < attachments.length; i++) {
            await controller.sendMessage(
              destination: to,
              text: i == 0 ? text : '',
              attachment: attachments[i],
            );
          }
        } catch (_) {
          failed.add(to);
        }
      }
    } on FormatException catch (error) {
      if (mounted) {
        setState(() => _sending = false);
        _snack(error.message);
      }
      return;
    }
    if (!mounted) return;
    if (failed.isEmpty) {
      sharedContent.set(null);
      context.pop();
      return;
    }
    setState(() {
      _sending = false;
      _selected
        ..clear()
        ..addAll(failed);
    });
    _snack(
      failed.length == 1
          ? 'It could not be sent to ${failed.first}. Try again.'
          : 'It could not be sent to ${failed.length} people. Try again.',
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(sharedContentProvider, (_, next) {
      if (next == null) return;
      setState(() {
        _text.text = next.text;
        _selected.clear();
        _typed.clear();
      });
    });
    final content = ref.watch(sharedContentProvider);
    final lines = ref.watch(messagingLinesProvider);
    final theme = Theme.of(context);
    final scaffold = Scaffold(
      appBar: AppBar(
        title: const Text('Send with VoipCloud'),
        leading: IconButton(
          tooltip: 'Cancel',
          icon: const Icon(Icons.close),
          onPressed: () {
            ref.read(sharedContentProvider.notifier).set(null);
            context.pop();
          },
        ),
      ),
    );
    if (content == null) return scaffold;
    if (lines.isEmpty) {
      return Scaffold(
        appBar: scaffold.appBar,
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Text messaging is not set up on this account.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    final line = lines.contains(_line)
        ? _line!
        : ref.watch(activeMessagingLineProvider);
    final state = ref.watch(messagesControllerForLineProvider(line));
    final contacts = ref.watch(contactsProvider).value ?? const [];
    final directory = ref.watch(directoryProvider).value ?? const [];
    final lineInfos = lines.length > 1
        ? [
            for (final info in ref.watch(accountLinesProvider))
              if (lines.contains(info.line)) info,
          ]
        : null;
    final recent =
        (state.threads.entries.toList()..sort((a, b) {
              final aTime = a.value.isEmpty
                  ? DateTime(0)
                  : a.value.last.createdAt;
              final bTime = b.value.isEmpty
                  ? DateTime(0)
                  : b.value.last.createdAt;
              return bTime.compareTo(aTime);
            }))
            .map((entry) => entry.key)
            .where((number) => !_typed.contains(number))
            .take(50);

    Widget tile(String number) {
      final identity = resolveRemoteIdentity(
        remoteUri: number,
        contacts: contacts,
        directory: directory,
      );
      return CheckboxListTile(
        value: _selected.contains(number),
        onChanged: _sending
            ? null
            : (checked) => setState(
                () => checked == true
                    ? _selected.add(number)
                    : _selected.remove(number),
              ),
        title: Text(identity.label),
        subtitle: identity.label == number ? null : Text(number),
        controlAffinity: ListTileControlAffinity.leading,
      );
    }

    return Scaffold(
      appBar: scaffold.appBar,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                children: [
                  if (content.files.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final file in content.files)
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Image.file(
                                File(file.path),
                                width: 84,
                                height: 84,
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) => const SizedBox(
                                  width: 84,
                                  height: 84,
                                  child: Icon(Icons.image_not_supported),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  TextField(
                    controller: _text,
                    minLines: 1,
                    maxLines: 5,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(
                      labelText: content.files.isEmpty ? 'Message' : 'Caption',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  if (lineInfos != null) ...[
                    const SizedBox(height: 12),
                    LineSegmented(
                      lines: lineInfos,
                      selected: line,
                      onSelected: (value) => setState(() {
                        _line = value;
                        _selected.clear();
                        _typed.clear();
                      }),
                    ),
                  ],
                  const SizedBox(height: 16),
                  Text('Send to', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _number,
                          keyboardType: TextInputType.phone,
                          onSubmitted: (_) => _addTypedNumber(line),
                          decoration: const InputDecoration(
                            labelText: 'New number',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filledTonal(
                        tooltip: 'Add number',
                        icon: const Icon(Icons.add),
                        onPressed: () => _addTypedNumber(line),
                      ),
                    ],
                  ),
                  for (final number in _typed) tile(number),
                  for (final number in recent) tile(number),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _sending || _selected.isEmpty
                      ? null
                      : () => _send(content, line),
                  child: _sending
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(
                          _selected.length > 1
                              ? 'Send to ${_selected.length} people'
                              : 'Send',
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
