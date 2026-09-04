import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/route_names.dart';
import '../../../app/theme/app_theme.dart';
import '../../../features/dialer/presentation/dialer_controller.dart';
import '../../../shared/icons/app_icons.dart';
import '../../../shared/widgets/app_card.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/page_content.dart';
import '../domain/contact.dart';
import 'contacts_providers.dart';

class ContactsScreen extends ConsumerWidget {
  const ContactsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final contacts = ref.watch(contactsProvider);

    return PageContent(
      maxWidth: 680,
      scrollable: false,
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      child: contacts.when(
        data: (items) => _ContactsPanel(
          contacts: items,
          onAdd: () => _showAddContactSheet(context, ref),
          onCall: (contact) => _callContact(context, ref, contact),
          onEdit: (contact) => _showEditContactSheet(context, ref, contact),
          onDelete: (contact) => _confirmDeleteContact(context, ref, contact),
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => AppCard(
          padding: const EdgeInsets.all(12),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 340),
              child: EmptyState(
                framed: false,
                icon: AppIcons.navContacts,
                title: 'No contacts',
                message: 'We could not load saved contacts on this device.',
                action: OutlinedButton.icon(
                  onPressed: () =>
                      ref.read(contactsProvider.notifier).refresh(),
                  icon: const Icon(AppIcons.refresh, size: AppIconSize.sm),
                  label: const Text('Try again'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showAddContactSheet(BuildContext context, WidgetRef ref) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => _ContactSheet(ref: ref),
    );
  }

  Future<void> _showEditContactSheet(
    BuildContext context,
    WidgetRef ref,
    Contact contact,
  ) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => _ContactSheet(ref: ref, contact: contact),
    );
  }

  Future<void> _callContact(
    BuildContext context,
    WidgetRef ref,
    Contact contact,
  ) async {
    final phoneNumber = contact.phoneNumber.trim();
    final extension = contact.extension?.trim() ?? '';
    if (phoneNumber.isNotEmpty && extension.isNotEmpty) {
      final destination = await showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        builder: (sheetContext) {
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    leading: const Icon(AppIcons.keypad),
                    title: const Text('Call extension'),
                    subtitle: Text(extension),
                    onTap: () => Navigator.of(sheetContext).pop(extension),
                  ),
                  ListTile(
                    leading: const Icon(AppIcons.call),
                    title: const Text('Call number with extension'),
                    subtitle: Text('$phoneNumber, $extension'),
                    onTap: () => Navigator.of(
                      sheetContext,
                    ).pop('$phoneNumber,$extension'),
                  ),
                ],
              ),
            ),
          );
        },
      );
      if (destination == null || destination.isEmpty) {
        return;
      }
      if (!context.mounted) {
        return;
      }
      _openDialer(context, ref, destination);
      return;
    }

    final destination = _contactDestination(contact);
    if (destination.isEmpty) {
      return;
    }
    _openDialer(context, ref, destination);
  }

  Future<void> _confirmDeleteContact(
    BuildContext context,
    WidgetRef ref,
    Contact contact,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Delete contact?'),
          content: Text('Remove ${contact.displayName} from contacts.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
    if (confirmed != true) {
      return;
    }
    await ref.read(contactsProvider.notifier).deleteContact(contact.id);
  }
}

void _openDialer(BuildContext context, WidgetRef ref, String destination) {
  final dialer = ref.read(dialerControllerProvider.notifier);
  dialer.clear();
  dialer.append(destination);
  context.go(RoutePaths.dialer);
}

class _ContactsPanel extends StatelessWidget {
  const _ContactsPanel({
    required this.contacts,
    required this.onAdd,
    required this.onCall,
    required this.onEdit,
    required this.onDelete,
  });

  final List<Contact> contacts;
  final VoidCallback onAdd;
  final ValueChanged<Contact> onCall;
  final ValueChanged<Contact> onEdit;
  final ValueChanged<Contact> onDelete;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: contacts.isEmpty
              ? Card(
                  clipBehavior: Clip.antiAlias,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 340),
                        child: const EmptyState(
                          framed: false,
                          icon: AppIcons.navContacts,
                          title: 'No contacts',
                          message:
                              'Use the add button to save frequently dialed people and extensions.',
                        ),
                      ),
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.only(bottom: 88),
                  itemCount: contacts.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final contact = contacts[index];
                    final destination = _contactDestination(contact);
                    return AppInfoTile(
                      icon: AppIcons.contact,
                      title: contact.displayName,
                      subtitle: _contactSubtitle(contact),
                      subtitleStyle: AppTheme.numberStyle(
                        Theme.of(context).textTheme.bodyMedium,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0,
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Call',
                            onPressed: destination.isEmpty
                                ? null
                                : () => onCall(contact),
                            icon: const Icon(
                              AppIcons.callForward,
                              size: AppIconSize.md,
                            ),
                          ),
                          PopupMenuButton<_ContactAction>(
                            tooltip: 'Contact actions',
                            icon: const Icon(AppIcons.moreVertical),
                            onSelected: (action) {
                              switch (action) {
                                case _ContactAction.edit:
                                  onEdit(contact);
                                  break;
                                case _ContactAction.delete:
                                  onDelete(contact);
                                  break;
                              }
                            },
                            itemBuilder: (context) => const [
                              PopupMenuItem(
                                value: _ContactAction.edit,
                                child: Row(
                                  children: [
                                    Icon(AppIcons.edit, size: AppIconSize.sm),
                                    SizedBox(width: 12),
                                    Text('Edit'),
                                  ],
                                ),
                              ),
                              PopupMenuItem(
                                value: _ContactAction.delete,
                                child: Row(
                                  children: [
                                    Icon(AppIcons.trash, size: AppIconSize.sm),
                                    SizedBox(width: 12),
                                    Text('Delete'),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
        Positioned(
          right: 16,
          bottom: 16,
          child: FloatingActionButton(
            onPressed: onAdd,
            child: const Icon(AppIcons.add),
          ),
        ),
      ],
    );
  }
}

enum _ContactAction { edit, delete }

class _ContactSheet extends StatefulWidget {
  const _ContactSheet({required this.ref, this.contact});

  final WidgetRef ref;
  final Contact? contact;

  @override
  State<_ContactSheet> createState() => _ContactSheetState();
}

class _ContactSheetState extends State<_ContactSheet> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _numberController = TextEditingController();
  final _extensionController = TextEditingController();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final contact = widget.contact;
    if (contact == null) {
      return;
    }
    _nameController.text = contact.displayName;
    _numberController.text = contact.phoneNumber;
    _extensionController.text = contact.extension ?? '';
  }

  @override
  void dispose() {
    _nameController.dispose();
    _numberController.dispose();
    _extensionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final editing = widget.contact != null;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 8, 20, 20 + bottomInset),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                editing ? 'Edit contact' : 'New contact',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _nameController,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  prefixIcon: Icon(AppIcons.contact),
                ),
                validator: (value) => value == null || value.trim().isEmpty
                    ? 'Enter a name'
                    : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _numberController,
                keyboardType: TextInputType.phone,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Phone number',
                  prefixIcon: Icon(AppIcons.call),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _extensionController,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: 'Extension',
                  prefixIcon: Icon(AppIcons.keypad),
                ),
                validator: (_) {
                  final number = _numberController.text.trim();
                  final extension = _extensionController.text.trim();
                  return number.isEmpty && extension.isEmpty
                      ? 'Enter a phone number or extension'
                      : null;
                },
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(editing ? AppIcons.edit : AppIcons.add),
                label: Text(editing ? 'Save changes' : 'Save contact'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    setState(() => _saving = true);
    try {
      final contact = widget.contact;
      if (contact == null) {
        await widget.ref
            .read(contactsProvider.notifier)
            .addContact(
              displayName: _nameController.text,
              phoneNumber: _numberController.text,
              extension: _extensionController.text,
            );
      } else {
        await widget.ref
            .read(contactsProvider.notifier)
            .updateContact(
              id: contact.id,
              displayName: _nameController.text,
              phoneNumber: _numberController.text,
              extension: _extensionController.text,
            );
      }
      if (mounted) {
        Navigator.of(context).pop();
      }
    } on ArgumentError catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.message.toString())));
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }
}

String _contactDestination(Contact contact) {
  final phoneNumber = contact.phoneNumber.trim();
  if (phoneNumber.isNotEmpty) {
    return phoneNumber;
  }
  return contact.extension?.trim() ?? '';
}

String _contactSubtitle(Contact contact) {
  final phoneNumber = contact.phoneNumber.trim();
  final extension = contact.extension?.trim() ?? '';
  if (extension.isNotEmpty && phoneNumber.isNotEmpty) {
    return 'Ext $extension - $phoneNumber';
  }
  if (extension.isNotEmpty) {
    return 'Ext $extension';
  }
  return phoneNumber;
}
