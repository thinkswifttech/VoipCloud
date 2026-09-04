import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../../app/router/route_names.dart';
import '../../../app/theme/app_theme.dart';
import '../../../core/files/downloads_saver.dart';
import '../../../features/dialer/presentation/dialer_controller.dart';
import '../../../features/directory/domain/directory_entry.dart';
import '../../../features/directory/presentation/directory_providers.dart';
import '../../../shared/icons/app_icons.dart';
import '../../../shared/widgets/empty_state.dart';
import '../data/device_contacts_repository.dart';
import '../domain/contact.dart';
import '../domain/quick_dial_csv.dart';
import '../domain/quick_dial_entry.dart';
import 'contacts_providers.dart';
import 'quick_dial_providers.dart';

class QuickDialPanel extends ConsumerWidget {
  const QuickDialPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final quickDial = ref.watch(quickDialProvider);

    return quickDial.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, _) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: EmptyState(
            framed: false,
            icon: AppIcons.quickDial,
            title: 'Quick Dial unavailable',
            message: 'We could not load your Quick Dial list.',
            action: OutlinedButton.icon(
              onPressed: () => ref.read(quickDialProvider.notifier).refresh(),
              icon: const Icon(AppIcons.refresh, size: AppIconSize.sm),
              label: const Text('Try again'),
            ),
          ),
        ),
      ),
      data: (entries) {
        if (entries.isEmpty) {
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: EmptyState(
                framed: false,
                icon: AppIcons.quickDial,
                title: 'No Quick Dial contacts',
                message:
                    'Add people from Contacts, Directory, or a new number '
                    'for one-tap calling.',
                action: FilledButton.icon(
                  onPressed: () =>
                      _showAddSheet(context, ref, canExport: false),
                  icon: const Icon(AppIcons.add, size: AppIconSize.sm),
                  label: const Text('Add to Quick Dial'),
                ),
              ),
            ),
          );
        }

        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.only(right: 12, bottom: 8),
              child: Align(
                alignment: Alignment.centerRight,
                child: FilledButton.tonalIcon(
                  onPressed: () => _showAddSheet(
                    context,
                    ref,
                    canExport: true,
                    entries: entries,
                  ),
                  icon: const Icon(AppIcons.add, size: AppIconSize.sm),
                  label: const Text('Add'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.avatarBackground(
                      Theme.of(context).brightness,
                    ),
                    foregroundColor: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
            ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: () => ref.read(quickDialProvider.notifier).refresh(),
                child: ListView.separated(
                  padding: const EdgeInsets.only(right: 12, bottom: 28),
                  itemCount: entries.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final entry = entries[index];
                    final canEdit = entry.source != QuickDialSource.directory;
                    return _QuickDialTile(
                      entry: entry,
                      onCall: () => _callEntry(context, ref, entry),
                      onEdit: canEdit
                          ? () => _showEditSheet(context, ref, entry)
                          : null,
                      onRemove: () => _confirmRemove(context, ref, entry),
                    );
                  },
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _exportCsv(
    BuildContext context,
    List<QuickDialEntry> entries,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '')
        .replaceAll('-', '')
        .split('.')
        .first;
    final fileName = 'thinkSwift_Voipcloud_quick_dial_$stamp.csv';
    try {
      final location = await AppFiles().saveText(
        fileName: fileName,
        content: QuickDialCsvCodec.encode(entries),
        mimeType: 'text/csv',
      );
      if (!context.mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('Saved to $location')));
    } on PlatformException catch (error) {
      if (!context.mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(error.message ?? 'Could not save Quick Dial CSV.'),
        ),
      );
    } catch (_) {
      if (!context.mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not save Quick Dial CSV.')),
      );
    }
  }

  Future<void> _importCsv(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final raw = await AppFiles().pickCsvText();
      if (raw == null) {
        return;
      }
      if (raw.trim().isEmpty) {
        if (!context.mounted) return;
        messenger.showSnackBar(
          const SnackBar(content: Text('The selected file is empty.')),
        );
        return;
      }
      final entries = QuickDialCsvCodec.decode(raw);
      if (entries.isEmpty) {
        if (!context.mounted) return;
        messenger.showSnackBar(
          const SnackBar(
            content: Text('No Quick Dial contacts found in that CSV.'),
          ),
        );
        return;
      }
      final enriched = _restoreMissingPhotos(
        entries,
        ref.read(contactsProvider).value ?? const [],
      );
      final summary = await ref
          .read(quickDialProvider.notifier)
          .importEntries(enriched);
      if (!context.mounted) return;
      final parts = <String>[
        if (summary.added > 0)
          'Added ${summary.added} '
              '${summary.added == 1 ? 'contact' : 'contacts'}',
        if (summary.skipped > 0)
          'skipped ${summary.skipped} duplicate'
              '${summary.skipped == 1 ? '' : 's'}',
      ];
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            parts.isEmpty ? 'Nothing imported.' : '${parts.join(', ')}.',
          ),
        ),
      );
    } on PlatformException catch (error) {
      if (!context.mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(error.message ?? 'Could not import Quick Dial CSV.'),
        ),
      );
    } catch (_) {
      if (!context.mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not import Quick Dial CSV.')),
      );
    }
  }

  List<QuickDialEntry> _restoreMissingPhotos(
    List<QuickDialEntry> entries,
    List<Contact> contacts,
  ) {
    if (entries.isEmpty || contacts.isEmpty) {
      return entries;
    }
    final byId = {for (final contact in contacts) contact.id: contact};
    return [
      for (final entry in entries)
        if (entry.photoBytes != null && entry.photoBytes!.isNotEmpty)
          entry
        else if (entry.source == QuickDialSource.contact &&
            entry.sourceId != null &&
            byId[entry.sourceId!]?.photo != null)
          QuickDialEntry(
            id: entry.id,
            displayName: entry.displayName,
            number: entry.number,
            source: entry.source,
            sourceId: entry.sourceId,
            photoBytes: byId[entry.sourceId!]!.photo,
            createdAt: entry.createdAt,
          )
        else
          entry,
    ];
  }

  void _callEntry(BuildContext context, WidgetRef ref, QuickDialEntry entry) {
    final destination = entry.number.trim();
    if (destination.isEmpty) {
      return;
    }
    ref.read(dialerControllerProvider.notifier)
      ..clear()
      ..append(destination);
    context.go(RoutePaths.dialer);
  }

  Future<void> _showAddSheet(
    BuildContext context,
    WidgetRef ref, {
    required bool canExport,
    List<QuickDialEntry> entries = const [],
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (_) => _AddQuickDialSheet(
        canExport: canExport,
        onImport: () => _importCsv(context, ref),
        onExport: canExport ? () => _exportCsv(context, entries) : null,
      ),
    );
  }

  Future<void> _showEditSheet(
    BuildContext context,
    WidgetRef ref,
    QuickDialEntry entry,
  ) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (_) => _EditQuickDialSheet(entry: entry),
    );
  }

  Future<void> _confirmRemove(
    BuildContext context,
    WidgetRef ref,
    QuickDialEntry entry,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Remove from Quick Dial?'),
          content: Text(
            '“${entry.displayName}” will be removed from Quick Dial only. '
            'Your Contacts and Directory are not changed.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              style: TextButton.styleFrom(foregroundColor: AppTheme.swiftRed),
              child: const Text('Remove'),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !context.mounted) {
      return;
    }
    await ref.read(quickDialProvider.notifier).remove(entry.id);
  }
}

class _QuickDialTile extends StatelessWidget {
  const _QuickDialTile({
    required this.entry,
    required this.onCall,
    required this.onEdit,
    required this.onRemove,
  });

  final QuickDialEntry entry;
  final VoidCallback onCall;
  final VoidCallback? onEdit;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canEdit = onEdit != null;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onCall,
        onLongPress: onEdit,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            children: [
              _QuickDialAvatar(entry: entry),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      entry.number,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTheme.numberStyle(theme.textTheme.bodyMedium),
                    ),
                  ],
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'Call ${entry.displayName}',
                onPressed: onCall,
                icon: const Icon(AppIcons.call),
              ),
              PopupMenuButton<_QuickDialAction>(
                tooltip: 'More',
                onSelected: (action) {
                  switch (action) {
                    case _QuickDialAction.edit:
                      onEdit?.call();
                    case _QuickDialAction.remove:
                      onRemove();
                  }
                },
                itemBuilder: (context) => [
                  if (canEdit)
                    const PopupMenuItem(
                      value: _QuickDialAction.edit,
                      child: ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(AppIcons.edit, size: AppIconSize.md),
                        title: Text('Edit'),
                      ),
                    ),
                  PopupMenuItem(
                    value: _QuickDialAction.remove,
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        AppIcons.trash,
                        size: AppIconSize.md,
                        color: AppTheme.swiftRed,
                      ),
                      title: Text(
                        'Remove',
                        style: TextStyle(color: AppTheme.swiftRed),
                      ),
                    ),
                  ),
                ],
                icon: const Icon(AppIcons.moreVertical),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _QuickDialAction { edit, remove }

class _QuickDialAvatar extends StatelessWidget {
  const _QuickDialAvatar({required this.entry});

  final QuickDialEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final photo = entry.photoBytes;
    const radius = 22.0;
    final decodeSize = (radius * 3).round().clamp(48, 128);

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
      child: photo == null
          ? Text(
              _initials(entry.displayName),
              style: TextStyle(
                fontSize: radius * 0.58,
                color: AppTheme.avatarForeground,
                fontWeight: FontWeight.w700,
              ),
            )
          : null,
    );
  }
}

class _AddQuickDialSheet extends StatelessWidget {
  const _AddQuickDialSheet({
    required this.canExport,
    required this.onImport,
    this.onExport,
  });

  final bool canExport;
  final VoidCallback onImport;
  final VoidCallback? onExport;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final supportsDeviceContacts = isDeviceContactsSupported();

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
          Text('Quick Dial', style: theme.textTheme.titleLarge),
          const SizedBox(height: 6),
          Text(
            'Add someone, or import and export your list.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          if (supportsDeviceContacts)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                AppIcons.navContacts,
                color: theme.colorScheme.primary,
              ),
              title: const Text('From contacts'),
              subtitle: const Text('Add someone from your phone contacts'),
              trailing: const Icon(AppIcons.chevronRight),
              onTap: () async {
                Navigator.of(context).pop();
                await showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  useSafeArea: true,
                  showDragHandle: true,
                  backgroundColor: theme.colorScheme.surface,
                  builder: (_) => const _PickContactSheet(),
                );
              },
            ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              AppIcons.navDirectory,
              color: theme.colorScheme.primary,
            ),
            title: const Text('From directory'),
            subtitle: const Text('Add a company or external directory entry'),
            trailing: const Icon(AppIcons.chevronRight),
            onTap: () async {
              Navigator.of(context).pop();
              await showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                useSafeArea: true,
                showDragHandle: true,
                backgroundColor: theme.colorScheme.surface,
                builder: (_) => const _PickDirectorySheet(),
              );
            },
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(AppIcons.add, color: theme.colorScheme.primary),
            title: const Text('New number'),
            subtitle: const Text('Enter a name, number, and optional photo'),
            trailing: const Icon(AppIcons.chevronRight),
            onTap: () async {
              Navigator.of(context).pop();
              await showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                useSafeArea: true,
                showDragHandle: true,
                backgroundColor: theme.colorScheme.surface,
                builder: (_) => const _QuickDialFormSheet(),
              );
            },
          ),
          const SizedBox(height: 8),
          Divider(
            height: 1,
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.55),
          ),
          const SizedBox(height: 8),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              AppIcons.importFile,
              color: theme.colorScheme.primary,
            ),
            title: const Text('Import CSV'),
            subtitle: const Text('Restore Quick Dial contacts from a file'),
            onTap: () {
              Navigator.of(context).pop();
              onImport();
            },
          ),
          if (canExport && onExport != null)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                AppIcons.exportFile,
                color: theme.colorScheme.primary,
              ),
              title: const Text('Export CSV'),
              subtitle: const Text('Save your Quick Dial list to Downloads'),
              onTap: () {
                Navigator.of(context).pop();
                onExport!();
              },
            ),
        ],
      ),
    );
  }
}

class _PickContactSheet extends ConsumerStatefulWidget {
  const _PickContactSheet();

  @override
  ConsumerState<_PickContactSheet> createState() => _PickContactSheetState();
}

class _PickContactSheetState extends ConsumerState<_PickContactSheet> {
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
                        message: 'Try a different search, or add a new number.',
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
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: _ContactPickAvatar(contact: contact),
                          title: Text(contact.displayName),
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
                      'Add which number to Quick Dial?',
                      style: Theme.of(sheetContext).textTheme.titleMedium,
                    ),
                  ),
                  for (final phone in phones)
                    ListTile(
                      leading: const Icon(AppIcons.star),
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
    await _addContact(contact, number);
  }

  Future<void> _addContact(Contact contact, String number) async {
    try {
      await ref
          .read(quickDialProvider.notifier)
          .add(
            displayName: contact.displayName.trim().isEmpty
                ? number
                : contact.displayName.trim(),
            number: number,
            source: QuickDialSource.contact,
            sourceId: contact.id,
            photoBytes: contact.photo,
          );
      if (!mounted) return;
      Navigator.of(context).pop();
    } on QuickDialDuplicateException {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$number is already in Quick Dial.')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not add this contact.')),
      );
    }
  }

  List<Contact> _filterContacts(List<Contact> contacts, String query) {
    if (query.isEmpty) {
      return contacts;
    }
    final lower = query.toLowerCase();
    return contacts.where((contact) {
      return contact.displayName.toLowerCase().contains(lower) ||
          contact.phoneNumber.toLowerCase().contains(lower) ||
          (contact.extension?.toLowerCase().contains(lower) ?? false);
    }).toList();
  }
}

class _ContactPickAvatar extends StatelessWidget {
  const _ContactPickAvatar({required this.contact});

  final Contact contact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final photo = contact.photo;
    return CircleAvatar(
      backgroundColor: AppTheme.avatarBackground(theme.brightness),
      foregroundColor: AppTheme.avatarForeground,
      backgroundImage: photo == null ? null : MemoryImage(photo),
      child: photo == null
          ? Text(
              _initials(
                contact.displayName.trim().isEmpty
                    ? contact.phoneNumber
                    : contact.displayName,
              ),
              style: const TextStyle(
                color: AppTheme.avatarForeground,
                fontWeight: FontWeight.w700,
              ),
            )
          : null,
    );
  }
}

class _PickDirectorySheet extends ConsumerStatefulWidget {
  const _PickDirectorySheet();

  @override
  ConsumerState<_PickDirectorySheet> createState() =>
      _PickDirectorySheetState();
}

class _PickDirectorySheetState extends ConsumerState<_PickDirectorySheet> {
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
              onChanged: (value) => setState(() => _query = value.trim()),
              onTapOutside: (_) =>
                  FocusManager.instance.primaryFocus?.unfocus(),
              decoration: InputDecoration(
                hintText: 'Search name, company, or number',
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
                        title: 'No directory matches',
                        message: 'Try a different search.',
                      ),
                    );
                  }
                  return ListView.separated(
                    itemCount: filtered.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final entry = filtered[index];
                      final subtitle = entry.company.trim().isEmpty
                          ? entry.extension
                          : '${entry.company}  ·  ${entry.extension}';
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: CircleAvatar(
                          backgroundColor: AppTheme.avatarBackground(
                            Theme.of(context).brightness,
                          ),
                          foregroundColor: AppTheme.avatarForeground,
                          child: Text(
                            _initials(entry.displayName),
                            style: const TextStyle(
                              color: AppTheme.avatarForeground,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        title: Text(entry.displayName),
                        subtitle: Text(
                          subtitle,
                          style: entry.company.trim().isEmpty
                              ? AppTheme.numberStyle(
                                  Theme.of(context).textTheme.bodyMedium,
                                )
                              : null,
                        ),
                        onTap: () => _addDirectory(entry),
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

  Future<void> _addDirectory(DirectoryEntry entry) async {
    try {
      await ref
          .read(quickDialProvider.notifier)
          .add(
            displayName: entry.displayName,
            number: entry.extension,
            source: QuickDialSource.directory,
            sourceId: entry.id,
          );
      if (!mounted) return;
      Navigator.of(context).pop();
    } on QuickDialDuplicateException {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${entry.extension} is already in Quick Dial.')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not add this directory entry.')),
      );
    }
  }

  List<DirectoryEntry> _filterDirectory(
    List<DirectoryEntry> entries,
    String query,
  ) {
    final usable = entries
        .where((entry) => entry.isCompany || entry.isExternal)
        .toList();
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

class _QuickDialFormSheet extends ConsumerStatefulWidget {
  const _QuickDialFormSheet({this.entry});

  final QuickDialEntry? entry;

  @override
  ConsumerState<_QuickDialFormSheet> createState() =>
      _QuickDialFormSheetState();
}

class _EditQuickDialSheet extends StatelessWidget {
  const _EditQuickDialSheet({required this.entry});

  final QuickDialEntry entry;

  @override
  Widget build(BuildContext context) {
    return _QuickDialFormSheet(entry: entry);
  }
}

class _QuickDialFormSheetState extends ConsumerState<_QuickDialFormSheet> {
  late final TextEditingController _nameController;
  late final TextEditingController _numberController;
  Uint8List? _photoBytes;
  var _clearPhoto = false;
  var _saving = false;

  @override
  void initState() {
    super.initState();
    final entry = widget.entry;
    _nameController = TextEditingController(text: entry?.displayName ?? '');
    _numberController = TextEditingController(text: entry?.number ?? '');
    _photoBytes = entry?.photoBytes;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _numberController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isEditing = widget.entry != null;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return Padding(
      padding: EdgeInsets.fromLTRB(20, 4, 20, 20 + bottomInset),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              isEditing ? 'Edit Quick Dial' : 'New Quick Dial contact',
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            Center(
              child: Column(
                children: [
                  CircleAvatar(
                    radius: 40,
                    backgroundColor: AppTheme.avatarBackground(
                      theme.brightness,
                    ),
                    foregroundColor: AppTheme.avatarForeground,
                    backgroundImage: _photoBytes == null
                        ? null
                        : MemoryImage(_photoBytes!),
                    child: _photoBytes == null
                        ? const Icon(AppIcons.person, size: 36)
                        : null,
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      TextButton(
                        onPressed: _saving ? null : _pickPhoto,
                        child: Text(
                          _photoBytes == null ? 'Add photo' : 'Change photo',
                        ),
                      ),
                      if (_photoBytes != null)
                        TextButton(
                          onPressed: _saving
                              ? null
                              : () => setState(() {
                                  _photoBytes = null;
                                  _clearPhoto = true;
                                }),
                          child: const Text('Remove'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _nameController,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.next,
              onTapOutside: (_) =>
                  FocusManager.instance.primaryFocus?.unfocus(),
              decoration: const InputDecoration(labelText: 'Display name'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _numberController,
              keyboardType: TextInputType.phone,
              textInputAction: TextInputAction.done,
              onTapOutside: (_) =>
                  FocusManager.instance.primaryFocus?.unfocus(),
              decoration: const InputDecoration(
                labelText: 'Phone number or extension',
              ),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: Text(isEditing ? 'Save changes' : 'Add to Quick Dial'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickPhoto() async {
    try {
      final file = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 512,
        maxHeight: 512,
        imageQuality: 72,
      );
      if (file == null) {
        return;
      }
      final bytes = await file.readAsBytes();
      if (!mounted) {
        return;
      }
      setState(() {
        _photoBytes = bytes;
        _clearPhoto = false;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Could not pick a photo.')));
    }
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    final number = _numberController.text.trim();
    if (name.isEmpty || number.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Name and number are required.')),
      );
      return;
    }

    setState(() => _saving = true);
    try {
      final notifier = ref.read(quickDialProvider.notifier);
      final existing = widget.entry;
      if (existing == null) {
        await notifier.add(
          displayName: name,
          number: number,
          source: QuickDialSource.custom,
          photoBytes: _photoBytes,
        );
      } else {
        await notifier.updateEntry(
          id: existing.id,
          displayName: name,
          number: number,
          photoBytes: _photoBytes,
          clearPhoto: _clearPhoto && _photoBytes == null,
        );
      }
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop();
    } on QuickDialDuplicateException {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$number is already in Quick Dial.')),
      );
    } catch (_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not save Quick Dial contact.')),
      );
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }
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
    return digits.isEmpty ? '?' : digits;
  }
  if (parts.length == 1) {
    final text = parts.first;
    return text.substring(0, text.length >= 2 ? 2 : 1).toUpperCase();
  }
  return '${parts.first.substring(0, 1)}${parts.last.substring(0, 1)}'
      .toUpperCase();
}
