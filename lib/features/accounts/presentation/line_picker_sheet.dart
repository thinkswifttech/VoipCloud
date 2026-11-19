import 'line_tone.dart';
import '../../../app/theme/app_theme.dart';
import 'package:flutter/material.dart';

import '../../../shared/widgets/app_modal_bottom_sheet.dart';
import '../domain/account_models.dart';
import 'accounts_controller.dart';
import 'line_widgets.dart';

/// The line the user picked, and whether to remember it as the default.
class LinePick {
  const LinePick(this.line, {required this.remember});

  final AccountLine line;
  final bool remember;
}

/// "Call from which account?" - shown when two accounts exist and nothing
/// else decides. Returns null when dismissed.
Future<LinePick?> showLinePickerSheet(
  BuildContext context, {
  required List<LineInfo> lines,
  String? destination,
  bool offerRemember = true,
}) {
  return showAppModalBottomSheet<LinePick>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _LinePickerSheet(
      lines: lines,
      destination: destination,
      offerRemember: offerRemember,
    ),
  );
}

class _LinePickerSheet extends StatefulWidget {
  const _LinePickerSheet({
    required this.lines,
    required this.destination,
    required this.offerRemember,
  });

  final List<LineInfo> lines;
  final String? destination;
  final bool offerRemember;

  @override
  State<_LinePickerSheet> createState() => _LinePickerSheetState();
}

class _LinePickerSheetState extends State<_LinePickerSheet> {
  bool _remember = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final destination = widget.destination?.trim() ?? '';
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Call from which account?', style: theme.textTheme.titleLarge),
            if (destination.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                'Calling $destination',
                style: AppTheme.digits(theme.textTheme.bodyMedium),
              ),
            ],
            const SizedBox(height: 12),
            for (final info in widget.lines)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                    side: BorderSide(
                      color: LineTone.of(context, info.colorValue).border,
                    ),
                  ),
                  onPressed: () => Navigator.pop(
                    context,
                    LinePick(info.line, remember: _remember),
                  ),
                  child: Row(
                    children: [
                      LineDot(colorValue: info.colorValue, size: 14),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              info.label,
                              style: AppTheme.digits(
                                theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            if (info.config != null)
                              Text(
                                info.config!.sipIdentity,
                                style: theme.textTheme.bodySmall,
                                overflow: TextOverflow.ellipsis,
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            if (widget.offerRemember)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _remember,
                onChanged: (value) =>
                    setState(() => _remember = value ?? false),
                title: const Text('Always use this account for new numbers'),
                subtitle: const Text('You can change this in Settings.'),
              ),
          ],
        ),
      ),
    );
  }
}
