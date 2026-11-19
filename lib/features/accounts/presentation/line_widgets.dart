import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../../sip/domain/sip_registration_state.dart';
import '../../sip/presentation/calling_status_text.dart';
import '../domain/account_line.dart';
import 'accounts_controller.dart';
import 'line_tone.dart';

/// A small coloured dot that identifies a line.
class LineDot extends StatelessWidget {
  const LineDot({required this.colorValue, this.size = 8, super.key});

  final int colorValue;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Color(colorValue),
        shape: BoxShape.circle,
      ),
    );
  }
}

/// The line's extension on its soft tint ("210"): compact enough for a list
/// row, and readable without relying on colour.
class LineTag extends StatelessWidget {
  const LineTag({required this.info, super.key});

  final LineInfo info;

  @override
  Widget build(BuildContext context) {
    final tone = LineTone.of(context, info.colorValue);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: tone.soft,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        info.shortLabel,
        maxLines: 1,
        style: AppTheme.digits(
          Theme.of(context).textTheme.labelSmall?.copyWith(
            color: tone.onSoft,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
          ),
        ),
      ),
    );
  }
}

/// The line's full label on its soft tint ("210 · swift") for a heading area,
/// such as the account a call is on.
class LineChip extends StatelessWidget {
  const LineChip({required this.info, super.key});

  final LineInfo info;

  @override
  Widget build(BuildContext context) {
    final tone = LineTone.of(context, info.colorValue);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: tone.soft,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          LineDot(colorValue: info.colorValue, size: 6),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              info.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTheme.digits(
                Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: tone.onSoft,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One control for choosing or filtering by account: a bordered row of
/// equal segments. The selected segment takes that line's soft tint and
/// outline; [allLabel] adds a neutral "All" segment (selected = null).
class LineSegmented extends StatelessWidget {
  const LineSegmented({
    required this.lines,
    required this.selected,
    required this.onSelected,
    this.allLabel,
    this.shortLabels = false,
    super.key,
  });

  final List<LineInfo> lines;
  final AccountLine? selected;
  final ValueChanged<AccountLine?> onSelected;
  final String? allLabel;

  /// Show the extension only ("210") instead of "210 · swift".
  final bool shortLabels;

  @override
  Widget build(BuildContext context) {
    final outline = Theme.of(context).colorScheme.outlineVariant;
    final segments = <Widget>[
      if (allLabel != null)
        _Segment(
          label: allLabel!,
          selected: selected == null,
          tone: null,
          onTap: () => onSelected(null),
        ),
      for (final info in lines)
        _Segment(
          label: shortLabels ? info.shortLabel : info.label,
          selected: selected == info.line,
          tone: LineTone.of(context, info.colorValue),
          onTap: () => onSelected(info.line),
        ),
    ];
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: outline),
      ),
      child: Row(
        children: [
          for (var i = 0; i < segments.length; i++) ...[
            if (i > 0) const SizedBox(width: 3),
            Expanded(child: segments[i]),
          ],
        ],
      ),
    );
  }
}

/// The account choice inside an expanding filter panel: a titled row of chips.
/// [allLabel] adds a neutral "All" chip (selected = null).
class LineChoiceRow extends StatelessWidget {
  const LineChoiceRow({
    required this.title,
    required this.lines,
    required this.selected,
    required this.onSelected,
    this.allLabel,
    super.key,
  });

  final String title;
  final List<LineInfo> lines;
  final AccountLine? selected;
  final ValueChanged<AccountLine?> onSelected;
  final String? allLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            if (allLabel != null)
              ChoiceChip(
                label: Text(allLabel!),
                selected: selected == null,
                showCheckmark: false,
                onSelected: (_) => onSelected(null),
              ),
            for (final info in lines)
              ChoiceChip(
                avatar: LineDot(colorValue: info.colorValue, size: 8),
                label: Text(info.label, style: AppTheme.digits(null)),
                selected: selected == info.line,
                showCheckmark: false,
                onSelected: (_) => onSelected(info.line),
              ),
          ],
        ),
      ],
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({
    required this.label,
    required this.selected,
    required this.tone,
    required this.onTap,
  });

  final String label;
  final bool selected;

  /// null for the neutral "All" segment.
  final LineTone? tone;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final background = !selected
        ? Colors.transparent
        : (tone?.soft ?? theme.colorScheme.surfaceContainerHighest);
    final foreground = !selected
        ? theme.colorScheme.onSurfaceVariant
        : (tone?.onSoft ?? theme.colorScheme.onSurface);
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: Material(
        color: background,
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          borderRadius: BorderRadius.circular(9),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 36),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: selected && tone != null
                ? BoxDecoration(
                    borderRadius: BorderRadius.circular(9),
                    border: Border.all(color: tone!.border),
                  )
                : null,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (tone != null) ...[
                  LineDot(colorValue: tone!.base.toARGB32(), size: 6),
                  const SizedBox(width: 6),
                ],
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTheme.digits(
                      theme.textTheme.labelLarge?.copyWith(
                        color: foreground,
                        fontWeight: selected
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
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
}

/// Connection wording and colour for one line's registration.
({String label, Color color}) lineStatus(
  BuildContext context,
  SipRegistrationState? state,
) {
  final status = state?.status ?? SipRegistrationStatus.uninitialized;
  final label = CallingStatusText.label(
    status,
    reconnecting: state?.reconnecting ?? false,
  );
  final color = switch (status) {
    SipRegistrationStatus.registered => const Color(0xFF16A34A),
    SipRegistrationStatus.failed => Theme.of(context).colorScheme.error,
    SipRegistrationStatus.registering ||
    SipRegistrationStatus.configuring => const Color(0xFFD97706),
    SipRegistrationStatus.uninitialized ||
    SipRegistrationStatus.unregistered => Theme.of(context).colorScheme.outline,
  };
  return (label: label, color: color);
}

/// "To ● 210 · swift" for a call on one of two accounts; nothing at all when
/// there is only one account or the call's account is unknown.
class CallLineBadge extends ConsumerWidget {
  const CallLineBadge({required this.line, this.prefix = 'To', super.key});

  final AccountLine? line;
  final String prefix;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (line == null || !ref.watch(hasSecondaryAccountProvider)) {
      return const SizedBox.shrink();
    }
    final info = ref
        .watch(accountLinesProvider)
        .where((candidate) => candidate.line == line)
        .firstOrNull;
    if (info == null) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$prefix ',
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        Flexible(child: LineChip(info: info)),
      ],
    );
  }
}
