import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/route_names.dart';
import '../../../app/theme/app_theme.dart';
import '../../../features/calls/presentation/caller_identity.dart';
import '../../../features/contacts/domain/contact.dart';
import '../../../features/contacts/domain/quick_dial_entry.dart';
import '../../../features/contacts/presentation/contacts_providers.dart';
import '../../../features/contacts/presentation/quick_dial_providers.dart';
import '../../../features/dialer/presentation/dialer_controller.dart';
import '../../../features/directory/domain/directory_entry.dart';
import '../../../features/directory/presentation/directory_providers.dart';
import '../../../shared/icons/app_icons.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/page_content.dart';
import '../../../shared/widgets/responsive.dart';
import '../domain/call_history_item.dart';
import 'call_history_providers.dart';

class _HistoryParty {
  const _HistoryParty({
    required this.number,
    required this.isKnown,
    this.displayName,
    this.photo,
  });

  final String number;
  final bool isKnown;
  final String? displayName;
  final Uint8List? photo;

  String get title {
    final name = displayName?.trim() ?? '';
    if (name.isNotEmpty) {
      return name;
    }
    if (number.isNotEmpty) {
      return number;
    }
    return 'Unknown';
  }

  bool get hasNamedContact {
    final name = displayName?.trim() ?? '';
    return isKnown && name.isNotEmpty;
  }
}

class CallHistoryScreen extends ConsumerStatefulWidget {
  const CallHistoryScreen({super.key});

  @override
  ConsumerState<CallHistoryScreen> createState() => _CallHistoryScreenState();
}

class _CallHistoryScreenState extends ConsumerState<CallHistoryScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(ref.read(missedCallCountProvider.notifier).markViewed());
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final history = ref.watch(callHistoryProvider);
    final contacts = ref.watch(contactsProvider).value ?? const <Contact>[];
    final quickDial =
        ref.watch(quickDialProvider).value ?? const <QuickDialEntry>[];
    final directory =
        ref.watch(directoryProvider).value ?? const <DirectoryEntry>[];

    return PageContent(
      maxWidth: ResponsiveContentWidths.list,
      desktopMaxWidth: ResponsiveContentWidths.desktopList,
      scrollable: false,
      safeAreaBottom: false,
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: history.when(
        data: (items) {
          if (items.isEmpty) {
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: const EmptyState(
                  framed: false,
                  icon: AppIcons.navHistory,
                  title: 'No calls yet',
                  message: 'Completed calls from this device will appear here.',
                ),
              ),
            );
          }

          return RefreshIndicator(
            onRefresh: () => ref.read(callHistoryProvider.notifier).refresh(),
            child: ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.only(bottom: 28),
              itemCount: _listEntryCount(items),
              itemBuilder: (context, index) {
                final entry = _listEntryAt(items, index);
                if (entry is _DateHeader) {
                  return _HistoryDateHeader(label: entry.label);
                }
                final item = (entry as _HistoryRow).item;
                return _CallHistoryTile(
                  item: item,
                  party: _partyForCaller(item, contacts, quickDial, directory),
                  onDial: (destination) {
                    ref
                        .read(dialerControllerProvider.notifier)
                        .setDestination(destination);
                    context.go(RoutePaths.dialer);
                  },
                );
              },
            ),
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: EmptyState(
              framed: false,
              icon: AppIcons.navHistory,
              title: 'History unavailable',
              message:
                  'We could not load call history. Pull to refresh and try again.',
              action: OutlinedButton.icon(
                onPressed: () =>
                    ref.read(callHistoryProvider.notifier).refresh(),
                icon: const Icon(AppIcons.refresh, size: AppIconSize.sm),
                label: const Text('Try again'),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DateHeader {
  const _DateHeader(this.label);
  final String label;
}

class _HistoryRow {
  const _HistoryRow(this.item);
  final CallHistoryItem item;
}

int _listEntryCount(List<CallHistoryItem> items) {
  if (items.isEmpty) {
    return 0;
  }
  var count = 0;
  String? lastDayKey;
  for (final item in items) {
    final key = _dayKey(item.startedAt);
    if (key != lastDayKey) {
      count += 1;
      lastDayKey = key;
    }
    count += 1;
  }
  return count;
}

Object _listEntryAt(List<CallHistoryItem> items, int index) {
  var cursor = 0;
  String? lastDayKey;
  for (final item in items) {
    final key = _dayKey(item.startedAt);
    if (key != lastDayKey) {
      if (cursor == index) {
        return _DateHeader(_dateSectionLabel(item.startedAt));
      }
      cursor += 1;
      lastDayKey = key;
    }
    if (cursor == index) {
      return _HistoryRow(item);
    }
    cursor += 1;
  }
  return _HistoryRow(items.last);
}

class _HistoryDateHeader extends StatelessWidget {
  const _HistoryDateHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 14, 2, 6),
      child: Text(
        label,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}

class _CallHistoryTile extends StatelessWidget {
  const _CallHistoryTile({
    required this.item,
    required this.party,
    required this.onDial,
  });

  final CallHistoryItem item;
  final _HistoryParty party;
  final ValueChanged<String> onDial;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final disposition = item.effectiveDisposition;
    final isMissed = disposition == CallHistoryDisposition.missed;
    final directionIcon = disposition == CallHistoryDisposition.outgoing
        ? AppIcons.callDirectionOut
        : AppIcons.callDirectionIn;
    final directionColor = isMissed
        ? theme.colorScheme.error
        : theme.colorScheme.onSurfaceVariant;
    final titleColor = isMissed
        ? theme.colorScheme.error
        : theme.colorScheme.onSurface;
    final title = party.title;
    final showNumberUnderName =
        party.hasNamedContact && party.number.isNotEmpty;
    final timeLabel = _timeLabel(item.startedAt);
    final durationLabel = _durationLabel(item.duration);
    final titleIsNumber = !party.hasNamedContact;
    final statusLabel = switch (disposition) {
      CallHistoryDisposition.outgoing => 'Outgoing',
      CallHistoryDisposition.answered => 'Answered',
      CallHistoryDisposition.answeredElsewhere => 'Answered elsewhere',
      CallHistoryDisposition.missed => 'Missed',
      CallHistoryDisposition.declined => 'Declined',
    };

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: party.number.isEmpty ? null : () => onDial(party.number),
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            children: [
              _HistoryAvatar(party: party),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: titleIsNumber
                          ? AppTheme.numberStyle(
                              theme.textTheme.bodyLarge,
                              color: titleColor,
                              fontWeight: FontWeight.w700,
                            )
                          : theme.textTheme.bodyLarge?.copyWith(
                              color: titleColor,
                              fontWeight: FontWeight.w700,
                            ),
                    ),
                    const SizedBox(height: 1),
                    Row(
                      children: [
                        Icon(directionIcon, size: 14, color: directionColor),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            showNumberUnderName
                                ? '${party.number} · $statusLabel'
                                : statusLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: isMissed
                                  ? theme.colorScheme.error
                                  : theme.colorScheme.onSurfaceVariant,
                              fontWeight: showNumberUnderName
                                  ? FontWeight.w500
                                  : null,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    durationLabel.isEmpty ? '—' : durationLabel,
                    style: AppTheme.numberStyle(
                      theme.textTheme.labelLarge,
                      color: theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    timeLabel,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              if (party.number.isNotEmpty)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Call $title',
                  onPressed: () => onDial(party.number),
                  icon: const Icon(AppIcons.call),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HistoryAvatar extends StatelessWidget {
  const _HistoryAvatar({required this.party});

  final _HistoryParty party;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final photo = party.photo;
    const radius = 22.0;
    final decodeSize = (radius * 3).round().clamp(48, 128);

    Widget? child;
    if (photo == null) {
      if (party.isKnown) {
        child = Text(
          _initials(
            party.displayName?.trim().isNotEmpty == true
                ? party.displayName!
                : party.number,
          ),
          style: theme.textTheme.titleSmall?.copyWith(
            color: AppTheme.avatarForeground,
            fontWeight: FontWeight.w700,
            fontSize: radius * 0.58,
          ),
        );
      } else {
        child = Icon(
          AppIcons.person,
          size: radius,
          color: AppTheme.avatarForeground,
        );
      }
    }

    return CircleAvatar(
      radius: radius,
      backgroundColor: AppTheme.avatarBackground(theme.brightness),
      foregroundColor: AppTheme.avatarForeground,
      backgroundImage: photo == null
          ? null
          : ResizeImage(
              MemoryImage(photo),
              width: decodeSize,
              height: decodeSize,
              policy: ResizeImagePolicy.fit,
            ),
      child: child,
    );
  }
}

_HistoryParty _partyForCaller(
  CallHistoryItem item,
  List<Contact> contacts,
  List<QuickDialEntry> quickDial,
  List<DirectoryEntry> directory,
) {
  // Resolve the stored SIP display name as well as the dialable identity. Queue
  // labels are commonly carried only as display text (for example
  // "SUP: Abdul"), including for callers not saved anywhere in the app.
  final identity = resolveRemoteIdentity(
    remoteUri: item.remoteNumber,
    remoteDisplayName: item.remoteDisplayName,
    contacts: contacts,
    quickDial: quickDial,
    directory: directory,
  );
  return _HistoryParty(
    number: identity.number,
    isKnown: identity.isResolvedName || identity.photo != null,
    displayName: identity.isResolvedName ? identity.label : null,
    photo: identity.photo,
  );
}

String _dayKey(DateTime value) {
  final local = value.toLocal();
  return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
}

String _dateSectionLabel(DateTime value) {
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

  const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
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
  final weekday = weekdays[local.weekday - 1];
  final month = months[local.month - 1];
  if (local.year == now.year) {
    return '$weekday, $month ${local.day}';
  }
  return '$weekday, $month ${local.day}, ${local.year}';
}

String _timeLabel(DateTime value) {
  final local = value.toLocal();
  final hour24 = local.hour;
  final minute = local.minute.toString().padLeft(2, '0');
  final period = hour24 >= 12 ? 'PM' : 'AM';
  final hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12;
  return '$hour12:$minute $period';
}

String _durationLabel(Duration? duration) {
  if (duration == null || duration.inSeconds <= 0) {
    return '';
  }
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:$seconds';
  }
  return '$minutes:$seconds';
}

String _initials(String value) {
  final parts = value
      .trim()
      .split(RegExp(r'\s+'))
      .where((part) => part.isNotEmpty)
      .toList();
  if (parts.isEmpty) {
    return '?';
  }

  final looksNumeric = RegExp(r'^[0-9+*#,]+$').hasMatch(parts.join());
  if (looksNumeric) {
    final digits = value.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length >= 2) {
      return digits.substring(digits.length - 2);
    }
    if (digits.isNotEmpty) {
      return digits;
    }
    return '?';
  }

  if (parts.length == 1) {
    final text = parts.first;
    return text.substring(0, text.length >= 2 ? 2 : 1).toUpperCase();
  }
  final first = parts.first.substring(0, 1);
  final last = parts.last.substring(0, 1);
  return '$first$last'.toUpperCase();
}
