import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/route_names.dart';
import '../../../core/errors/app_exception.dart';
import '../../dialer/presentation/dialer_controller.dart';
import '../../session/presentation/session_controller.dart';
import '../domain/call_status.dart';
import 'call_session_providers.dart';
import 'call_waiting_presentation.dart';

/// A second call can be started while one call is active or already on hold.
bool canAddCall(WidgetRef ref) {
  final call = ref.read(displayedInCallProvider);
  return isInCallUiCall(call) &&
      (call!.status == CallStatus.active || call.status == CallStatus.held) &&
      ref.read(sipServiceProvider).liveCalls.length == 1;
}

/// Contacts, the directory and call history put a number in the dial pad and
/// open Dial. While a call is on screen Dial shows that call instead of the
/// dial pad, so the number would never be dialed: ask to add it as a call.
void openDialerOrAddCall(BuildContext context, WidgetRef ref) {
  final number = ref.read(dialerControllerProvider);
  if (number.isNotEmpty && canAddCall(ref)) {
    ref.read(dialerControllerProvider.notifier).clear();
    showAddCallDialog(context, ref, initial: number);
    return;
  }
  context.go(RoutePaths.dialer);
}

/// Asks for a number, puts the current call on hold (if it is not already) and
/// dials the number as a second call.
Future<void> showAddCallDialog(
  BuildContext context,
  WidgetRef ref, {
  String initial = '',
}) async {
  final entered = await showDialog<String>(
    context: context,
    builder: (_) => _AddCallDialog(initial: normalizeDialDestination(initial)),
  );
  final number = normalizeDialDestination(entered ?? '');
  if (number.isEmpty || !context.mounted) return;

  final service = ref.read(sipServiceProvider);
  final messenger = ScaffoldMessenger.of(context);
  final current = ref.read(displayedInCallProvider);
  var heldHere = false;
  try {
    if (current != null) {
      // Puts the call on hold and waits until it really is held (it is also
      // what an attended transfer does first); a second call started before
      // that is refused by the engine.
      final wasActive = current.status == CallStatus.active;
      await service.prepareAttendedTransfer(current.id);
      heldHere = wasActive;
    }
    await service.makeCall(number);
  } catch (error) {
    if (heldHere && current != null) {
      try {
        await service.resume(current.id);
      } catch (_) {
        // The real call state stays visible, so the user can resume by hand.
      }
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          error is AppException
              ? error.userMessage
              : "Couldn't start the call. Please try again.",
        ),
      ),
    );
  }
}

class _AddCallDialog extends StatefulWidget {
  const _AddCallDialog({required this.initial});

  final String initial;

  @override
  State<_AddCallDialog> createState() => _AddCallDialogState();
}

class _AddCallDialogState extends State<_AddCallDialog> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add a call'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Your current call will be put on hold.'),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            autofocus: true,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(labelText: 'Number'),
            onSubmitted: (value) => Navigator.of(context).pop(value),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('Call'),
        ),
      ],
    );
  }
}
