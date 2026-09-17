import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/route_names.dart';
import '../../../app/theme/app_theme.dart';
import '../../../features/dialer/presentation/dialer_controller.dart';
import '../../../features/messages/domain/messaging_platform.dart';
import '../../../features/session/presentation/session_controller.dart';
import '../../../shared/icons/app_icons.dart';
import '../../../shared/widgets/app_card.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/page_content.dart';
import '../../../shared/widgets/responsive.dart';
import '../data/device_contacts_repository.dart';
import '../domain/contact.dart';
import '../domain/contact_number_eligibility.dart';
import '../domain/quick_dial_entry.dart';
import 'contacts_providers.dart';
import 'contacts_ui_provider.dart';
import 'quick_dial_panel.dart';
import 'quick_dial_providers.dart';

enum _ContactsTab { contacts, quickDial }

class DeviceContactsScreen extends ConsumerStatefulWidget {
  const DeviceContactsScreen({super.key});

  @override
  ConsumerState<DeviceContactsScreen> createState() =>
      _DeviceContactsScreenState();
}

class _DeviceContactsScreenState extends ConsumerState<DeviceContactsScreen> {
  final _searchController = TextEditingController();
  String _query = '';
  _ContactSort _sort = _ContactSort.firstName;
  bool _ascending = true;
  bool _showAddContactLabel = true;
  _ContactsTab _tab = _ContactsTab.contacts;
  Timer? _collapseAddContactTimer;
  List<Contact>? _lastContactsInput;
  List<Contact>? _lastVisibleContacts;
  String? _lastQuery;
  _ContactSort? _lastSort;
  bool? _lastAscending;

  @override
  void initState() {
    super.initState();
    ref.read(contactsUiProvider.notifier).pruneStaleQuery();
    final savedQuery = ref.read(contactsUiProvider).query;
    _query = savedQuery;
    if (savedQuery.isNotEmpty) {
      _searchController.text = savedQuery;
      _searchController.selection = TextSelection.collapsed(
        offset: savedQuery.length,
      );
    }
    _collapseAddContactTimer = Timer(const Duration(milliseconds: 1800), () {
      if (mounted) setState(() => _showAddContactLabel = false);
    });
  }

  @override
  void dispose() {
    _collapseAddContactTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!isDeviceContactsSupported()) {
      return const PageContent(
        maxWidth: ResponsiveContentWidths.list,
        desktopMaxWidth: ResponsiveContentWidths.desktopList,
        scrollable: false,
        safeAreaBottom: false,
        padding: EdgeInsets.fromLTRB(20, 12, 8, 0),
        child: QuickDialPanel(),
      );
    }

    final contacts = ref.watch(contactsProvider);
    final theme = Theme.of(context);

    return PageContent(
      maxWidth: ResponsiveContentWidths.list,
      desktopMaxWidth: ResponsiveContentWidths.desktopList,
      scrollable: false,
      safeAreaBottom: false,
      padding: const EdgeInsets.fromLTRB(20, 12, 8, 0),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: SizedBox(
              width: double.infinity,
              child: SegmentedButton<_ContactsTab>(
                expandedInsets: EdgeInsets.zero,
                showSelectedIcon: false,
                style: SegmentedButton.styleFrom(
                  selectedBackgroundColor: theme.colorScheme.primary,
                  selectedForegroundColor: theme.colorScheme.onPrimary,
                  backgroundColor: theme.colorScheme.surface,
                  foregroundColor: theme.colorScheme.onSurfaceVariant,
                  side: BorderSide(color: theme.colorScheme.outline),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                ),
                segments: const [
                  ButtonSegment(
                    value: _ContactsTab.contacts,
                    label: Text('Contacts'),
                    icon: Icon(AppIcons.navContacts, size: AppIconSize.sm),
                  ),
                  ButtonSegment(
                    value: _ContactsTab.quickDial,
                    label: Text('Quick Dial'),
                    icon: Icon(AppIcons.quickDial, size: AppIconSize.sm),
                  ),
                ],
                selected: {_tab},
                onSelectionChanged: (selection) {
                  if (selection.isNotEmpty) {
                    FocusManager.instance.primaryFocus?.unfocus();
                    setState(() => _tab = selection.first);
                  }
                },
              ),
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: switch (_tab) {
              _ContactsTab.contacts => contacts.when(
                data: (items) => _PhoneContactsPanel(
                  contacts: _visibleContacts(items),
                  totalCount: items.length,
                  searchController: _searchController,
                  query: _query,
                  sort: _sort,
                  ascending: _ascending,
                  onQueryChanged: (value) {
                    final trimmed = value.trim();
                    setState(() => _query = trimmed);
                    ref.read(contactsUiProvider.notifier).setQuery(trimmed);
                  },
                  onSortChanged: (value) => setState(() => _sort = value),
                  onToggleDirection: () =>
                      setState(() => _ascending = !_ascending),
                  onRefresh: () =>
                      ref.read(contactsProvider.notifier).refresh(),
                  onAdd: _addContact,
                  showAddContactLabel: _showAddContactLabel,
                  onCall: _callContact,
                  onMessage: _messageContact,
                  onOpen: _openContact,
                ),
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (error, _) => _ContactsError(
                  error: error,
                  onRetry: () => ref.read(contactsProvider.notifier).refresh(),
                  onOpenSettings: () =>
                      ref.read(contactsProvider.notifier).openSettings(),
                ),
              ),
              _ContactsTab.quickDial => const QuickDialPanel(),
            },
          ),
        ],
      ),
    );
  }

  List<Contact> _visibleContacts(List<Contact> contacts) {
    if (identical(_lastContactsInput, contacts) &&
        _lastQuery == _query &&
        _lastSort == _sort &&
        _lastAscending == _ascending) {
      return _lastVisibleContacts!;
    }

    final visibleContacts = _filteredAndSorted(contacts);
    _lastContactsInput = contacts;
    _lastVisibleContacts = visibleContacts;
    _lastQuery = _query;
    _lastSort = _sort;
    _lastAscending = _ascending;
    return visibleContacts;
  }

  List<Contact> _filteredAndSorted(List<Contact> contacts) {
    final query = _query.toLowerCase();
    final filtered = query.isEmpty
        ? contacts.toList()
        : contacts.where((contact) {
            final values = [
              contact.displayName,
              contact.firstName ?? '',
              contact.lastName ?? '',
              contact.company ?? '',
              contact.phoneNumber,
              contact.extension ?? '',
              ...contact.phones.map((phone) => phone.number),
            ];
            return values.any((value) => value.toLowerCase().contains(query));
          }).toList();
    filtered.sort((a, b) {
      final aValue = _sortValue(a);
      final bValue = _sortValue(b);
      final result = aValue.compareTo(bValue);
      if (result != 0) return _ascending ? result : -result;
      final fallback = a.displayName.toLowerCase().compareTo(
        b.displayName.toLowerCase(),
      );
      return _ascending ? fallback : -fallback;
    });
    return filtered;
  }

  String _sortValue(Contact contact) {
    final value = switch (_sort) {
      _ContactSort.firstName => contact.firstName,
      _ContactSort.lastName => contact.lastName,
      _ContactSort.displayName => contact.displayName,
      _ContactSort.company => contact.company,
    };
    final normalized = value?.trim().toLowerCase() ?? '';
    return normalized.isEmpty ? contact.displayName.toLowerCase() : normalized;
  }

  Future<void> _addContact() async {
    try {
      await ref.read(contactsProvider.notifier).addContact();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not open the phone contact editor.'),
        ),
      );
    }
  }

  Future<void> _callContact(Contact contact) async {
    final destination = await _pickNumber(
      contact,
      title: 'Call which number?',
      icon: AppIcons.call,
    );
    if (!mounted) return;
    if (destination == null || destination.isEmpty) {
      if (_actionablePhones(contact).isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No phone number available to call.')),
        );
      }
      return;
    }
    ref.read(dialerControllerProvider.notifier)
      ..clear()
      ..append(destination);
    context.go(RoutePaths.dialer);
  }

  Future<void> _messageContact(Contact contact) async {
    final destination = await _pickNumber(
      contact,
      title: 'Message which number?',
      icon: AppIcons.messages,
    );
    if (!mounted) return;
    if (destination == null || destination.isEmpty) {
      if (_actionablePhones(contact).isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No phone number available to message.'),
          ),
        );
      }
      return;
    }
    context.go(
      Uri(
        path: RoutePaths.messages,
        queryParameters: {'to': destination},
      ).toString(),
    );
  }

  Future<String?> _pickNumber(
    Contact contact, {
    required String title,
    required IconData icon,
  }) async {
    final phones = _actionablePhones(contact);
    if (phones.isEmpty) return null;
    if (phones.length == 1) return phones.first.number;

    return showModalBottomSheet<String>(
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
                    title,
                    style: Theme.of(sheetContext).textTheme.titleMedium,
                  ),
                ),
                for (final phone in phones)
                  ListTile(
                    leading: Icon(icon),
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

  List<ContactPhone> _actionablePhones(Contact contact) {
    final dialable = contact.dialablePhones;
    final eligible = dialable
        .where((phone) => isUsOrCanadianNumber(phone.number))
        .toList(growable: false);
    return eligible.isNotEmpty ? eligible : dialable;
  }

  Future<void> _openContact(Contact contact) {
    final brightness = Theme.of(context).brightness;
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: AppTheme.sheetSurface(brightness),
      builder: (_) => _ContactDetailsSheet(
        contact: contact,
        loadContact: () =>
            ref.read(contactsProvider.notifier).getContact(contact.id),
        onEdit: () =>
            ref.read(contactsProvider.notifier).editContact(contact.id),
        onCall: _callContact,
        onMessage: _messageContact,
      ),
    );
  }
}

class _PhoneContactsPanel extends StatefulWidget {
  const _PhoneContactsPanel({
    required this.contacts,
    required this.totalCount,
    required this.searchController,
    required this.query,
    required this.sort,
    required this.ascending,
    required this.onQueryChanged,
    required this.onSortChanged,
    required this.onToggleDirection,
    required this.onRefresh,
    required this.onAdd,
    required this.showAddContactLabel,
    required this.onCall,
    required this.onMessage,
    required this.onOpen,
  });

  final List<Contact> contacts;
  final int totalCount;
  final TextEditingController searchController;
  final String query;
  final _ContactSort sort;
  final bool ascending;
  final ValueChanged<String> onQueryChanged;
  final ValueChanged<_ContactSort> onSortChanged;
  final VoidCallback onToggleDirection;
  final Future<void> Function() onRefresh;
  final VoidCallback onAdd;
  final bool showAddContactLabel;
  final Future<void> Function(Contact contact) onCall;
  final Future<void> Function(Contact contact) onMessage;
  final ValueChanged<Contact> onOpen;

  @override
  State<_PhoneContactsPanel> createState() => _PhoneContactsPanelState();
}

class _PhoneContactsPanelState extends State<_PhoneContactsPanel> {
  static const _sectionHeaderHeight = 28.0;
  static const _contactTileHeight = 64.0;
  static const _listBottomPadding = 88.0;
  static const _indexBarWidth = 24.0;

  final _scrollController = ScrollController();
  final _activeSectionIndex = ValueNotifier<int>(0);
  final _showIndexBubble = ValueNotifier<bool>(false);
  List<_ContactListEntry> _entries = const [];
  List<_ContactSection> _sections = const [];
  List<String> _sectionTags = const [];
  bool _indexDragging = false;
  bool _showSortFilters = false;
  Timer? _hideIndexBubbleTimer;

  @override
  void initState() {
    super.initState();
    _rebuildEntries();
    _scrollController.addListener(_syncActiveSection);
  }

  @override
  void didUpdateWidget(covariant _PhoneContactsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.contacts, widget.contacts) ||
        oldWidget.sort != widget.sort ||
        oldWidget.ascending != widget.ascending) {
      _rebuildEntries();
    }
  }

  @override
  void dispose() {
    _hideIndexBubbleTimer?.cancel();
    _scrollController
      ..removeListener(_syncActiveSection)
      ..dispose();
    _activeSectionIndex.dispose();
    _showIndexBubble.dispose();
    super.dispose();
  }

  bool get _isDefaultSort =>
      widget.sort == _ContactSort.firstName && widget.ascending;

  void _rebuildEntries() {
    final entries = <_ContactListEntry>[];
    final sections = <_ContactSection>[];
    var offset = 0.0;
    String? currentTag;

    for (final contact in widget.contacts) {
      final tag = _sectionTag(contact, widget.sort);
      if (tag != currentTag) {
        currentTag = tag;
        sections.add(_ContactSection(tag: tag, offset: offset));
        entries.add(_ContactListEntry.header(tag));
        offset += _sectionHeaderHeight;
      }
      entries.add(_ContactListEntry.contact(contact));
      offset += _contactTileHeight;
    }

    _entries = entries;
    _sections = sections;
    _sectionTags = [for (final section in sections) section.tag];
    if (_activeSectionIndex.value >= sections.length) {
      _activeSectionIndex.value = sections.isEmpty ? 0 : sections.length - 1;
    }
  }

  void _syncActiveSection() {
    if (_indexDragging || _sections.isEmpty || !_scrollController.hasClients) {
      return;
    }

    final currentOffset = _scrollController.offset + _sectionHeaderHeight;
    var nextIndex = 0;
    for (var index = 0; index < _sections.length; index++) {
      if (_sections[index].offset <= currentOffset) {
        nextIndex = index;
      } else {
        break;
      }
    }

    if (nextIndex != _activeSectionIndex.value) {
      _activeSectionIndex.value = nextIndex;
    }
  }

  void _selectSection(int index, {required bool dragging}) {
    if (_sections.isEmpty || index < 0 || index >= _sections.length) {
      return;
    }

    _indexDragging = dragging;
    _activeSectionIndex.value = index;
    _showIndexBubble.value = true;
    _hideIndexBubbleTimer?.cancel();

    if (!_scrollController.hasClients) {
      return;
    }

    final targetOffset = _sections[index].offset
        .clamp(
          _scrollController.position.minScrollExtent,
          _scrollController.position.maxScrollExtent,
        )
        .toDouble();

    if (dragging) {
      _scrollController.jumpTo(targetOffset);
      return;
    }

    _scrollController.animateTo(
      targetOffset,
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOutCubic,
    );
    _scheduleHideBubble();
  }

  void _endIndexInteraction() {
    _indexDragging = false;
    _scheduleHideBubble();
  }

  void _scheduleHideBubble() {
    _hideIndexBubbleTimer?.cancel();
    _hideIndexBubbleTimer = Timer(const Duration(milliseconds: 420), () {
      if (mounted) _showIndexBubble.value = false;
    });
  }

  double? _extentForIndex(int index, _) {
    if (index < 0 || index >= _entries.length) {
      return null;
    }
    return _entries[index].contact == null
        ? _sectionHeaderHeight
        : _contactTileHeight;
  }

  @override
  Widget build(BuildContext context) {
    final showIndex = _sectionTags.length > 1;
    return Stack(
      fit: StackFit.expand,
      children: [
        Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: widget.searchController,
                    onChanged: widget.onQueryChanged,
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      hintText: 'Search names, company, or phone',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: widget.query.isEmpty
                          ? null
                          : IconButton(
                              tooltip: 'Clear search',
                              onPressed: () {
                                widget.searchController.clear();
                                widget.onQueryChanged('');
                              },
                              icon: const Icon(AppIcons.close),
                            ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.outlined(
                  tooltip: _showSortFilters
                      ? 'Hide sort options'
                      : 'Sort options',
                  onPressed: () =>
                      setState(() => _showSortFilters = !_showSortFilters),
                  style: IconButton.styleFrom(
                    foregroundColor: _isDefaultSort && !_showSortFilters
                        ? null
                        : Theme.of(context).colorScheme.primary,
                    side: BorderSide(
                      color: _isDefaultSort && !_showSortFilters
                          ? Theme.of(context).colorScheme.outline
                          : Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  icon: const Icon(AppIcons.filter),
                ),
              ],
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: _showSortFilters
                  ? Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Row(
                        children: [
                          Expanded(
                            child: DropdownButtonFormField<_ContactSort>(
                              key: ValueKey(widget.sort),
                              initialValue: widget.sort,
                              isExpanded: true,
                              decoration: const InputDecoration(
                                labelText: 'Sort by',
                              ),
                              items: _ContactSort.values
                                  .map(
                                    (option) => DropdownMenuItem(
                                      value: option,
                                      child: Text(
                                        option.label,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  )
                                  .toList(),
                              onChanged: (value) {
                                if (value != null) widget.onSortChanged(value);
                              },
                            ),
                          ),
                          const SizedBox(width: 4),
                          IconButton(
                            tooltip: widget.ascending
                                ? 'Sort descending'
                                : 'Sort ascending',
                            onPressed: widget.onToggleDirection,
                            icon: Icon(
                              widget.ascending
                                  ? Icons.arrow_upward
                                  : Icons.arrow_downward,
                            ),
                          ),
                        ],
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: widget.contacts.isEmpty
                  ? _EmptyContacts(
                      query: widget.query,
                      totalCount: widget.totalCount,
                    )
                  : RefreshIndicator(
                      onRefresh: widget.onRefresh,
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          return Stack(
                            clipBehavior: Clip.none,
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Expanded(
                                    child: Stack(
                                      children: [
                                        ListView.builder(
                                          controller: _scrollController,
                                          physics:
                                              const AlwaysScrollableScrollPhysics(),
                                          scrollCacheExtent:
                                              const ScrollCacheExtent.pixels(
                                                960,
                                              ),
                                          addAutomaticKeepAlives: false,
                                          addRepaintBoundaries: false,
                                          itemExtentBuilder: _extentForIndex,
                                          padding: const EdgeInsets.only(
                                            bottom: _listBottomPadding,
                                          ),
                                          itemCount: _entries.length,
                                          itemBuilder: (context, index) {
                                            final entry = _entries[index];
                                            final contact = entry.contact;
                                            if (contact == null) {
                                              return _ContactSectionHeader(
                                                tag: entry.tag,
                                              );
                                            }
                                            return _ContactTile(
                                              key: ValueKey(contact.id),
                                              contact: contact,
                                              onTap: () =>
                                                  widget.onOpen(contact),
                                              onCall: () =>
                                                  widget.onCall(contact),
                                              onMessage: () =>
                                                  widget.onMessage(contact),
                                            );
                                          },
                                        ),
                                        Positioned(
                                          top: 0,
                                          left: 0,
                                          right: 0,
                                          child: ValueListenableBuilder<int>(
                                            valueListenable:
                                                _activeSectionIndex,
                                            builder: (context, activeIndex, _) {
                                              if (_sectionTags.isEmpty) {
                                                return const SizedBox.shrink();
                                              }
                                              return _StickyContactSectionHeader(
                                                tag: _sectionTags[activeIndex],
                                              );
                                            },
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (showIndex)
                                    SizedBox(
                                      width: _indexBarWidth,
                                      child: Padding(
                                        padding: const EdgeInsets.only(
                                          bottom: _listBottomPadding,
                                        ),
                                        child: ValueListenableBuilder<int>(
                                          valueListenable: _activeSectionIndex,
                                          builder: (context, activeIndex, _) {
                                            return _ContactIndexBar(
                                              tags: _sectionTags,
                                              activeIndex: activeIndex,
                                              onSelect: (index) =>
                                                  _selectSection(
                                                    index,
                                                    dragging: false,
                                                  ),
                                              onDragSelect: (index) =>
                                                  _selectSection(
                                                    index,
                                                    dragging: true,
                                                  ),
                                              onDragEnd: _endIndexInteraction,
                                            );
                                          },
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                              if (showIndex)
                                ValueListenableBuilder<bool>(
                                  valueListenable: _showIndexBubble,
                                  builder: (context, visible, _) {
                                    return ValueListenableBuilder<int>(
                                      valueListenable: _activeSectionIndex,
                                      builder: (context, activeIndex, _) {
                                        final tag = _sectionTags.isEmpty
                                            ? ''
                                            : _sectionTags[activeIndex];
                                        const bubbleSize = 44.0;
                                        final availableHeight =
                                            (constraints.maxHeight -
                                                    _listBottomPadding)
                                                .clamp(0.0, double.infinity);
                                        final layout =
                                            _ContactIndexBar.layoutFor(
                                              tagCount: _sectionTags.length,
                                              availableHeight: availableHeight,
                                            );
                                        final top =
                                            (layout.topInset +
                                                    activeIndex *
                                                        layout.slotHeight +
                                                    (layout.slotHeight -
                                                            bubbleSize) /
                                                        2)
                                                .clamp(
                                                  0.0,
                                                  (constraints.maxHeight -
                                                          bubbleSize)
                                                      .clamp(
                                                        0.0,
                                                        double.infinity,
                                                      ),
                                                );
                                        return Positioned(
                                          top: top,
                                          right: _indexBarWidth + 6,
                                          child: IgnorePointer(
                                            child: AnimatedOpacity(
                                              opacity: visible ? 1 : 0,
                                              duration: const Duration(
                                                milliseconds: 100,
                                              ),
                                              curve: Curves.easeOut,
                                              child: AnimatedScale(
                                                scale: visible ? 1 : .92,
                                                duration: const Duration(
                                                  milliseconds: 120,
                                                ),
                                                curve: Curves.easeOutCubic,
                                                child: _IndexBubble(
                                                  tag: tag,
                                                  size: bubbleSize,
                                                ),
                                              ),
                                            ),
                                          ),
                                        );
                                      },
                                    );
                                  },
                                ),
                            ],
                          );
                        },
                      ),
                    ),
            ),
          ],
        ),
        Positioned(
          right: 8,
          bottom: 8,
          child: _CollapsingAddContactButton(
            onPressed: widget.onAdd,
            expanded: widget.showAddContactLabel,
          ),
        ),
      ],
    );
  }
}

class _ContactListEntry {
  const _ContactListEntry._({required this.tag, this.contact});

  factory _ContactListEntry.header(String tag) => _ContactListEntry._(tag: tag);

  factory _ContactListEntry.contact(Contact contact) =>
      _ContactListEntry._(tag: '', contact: contact);

  final String tag;
  final Contact? contact;
}

class _ContactSection {
  const _ContactSection({required this.tag, required this.offset});

  final String tag;
  final double offset;
}

class _ContactSectionHeader extends StatelessWidget {
  const _ContactSectionHeader({required this.tag});

  final String tag;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: _PhoneContactsPanelState._sectionHeaderHeight,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Text(
            tag,
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w700,
              letterSpacing: .2,
            ),
          ),
        ),
      ),
    );
  }
}

class _StickyContactSectionHeader extends StatelessWidget {
  const _StickyContactSectionHeader({required this.tag});

  final String tag;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: .96),
        border: Border(
          bottom: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(alpha: .45),
          ),
        ),
      ),
      child: _ContactSectionHeader(tag: tag),
    );
  }
}

class _ContactIndexBar extends StatelessWidget {
  const _ContactIndexBar({
    required this.tags,
    required this.activeIndex,
    required this.onSelect,
    required this.onDragSelect,
    required this.onDragEnd,
  });

  static const minSlotHeight = 15.0;
  static const maxSlotHeight = 22.0;

  final List<String> tags;
  final int activeIndex;
  final ValueChanged<int> onSelect;
  final ValueChanged<int> onDragSelect;
  final VoidCallback onDragEnd;

  static ({bool fillHeight, double slotHeight, double topInset}) layoutFor({
    required int tagCount,
    required double availableHeight,
  }) {
    if (tagCount <= 0 || availableHeight <= 0) {
      return (fillHeight: true, slotHeight: maxSlotHeight, topInset: 0);
    }
    final evenly = availableHeight / tagCount;
    if (evenly <= maxSlotHeight) {
      return (
        fillHeight: true,
        slotHeight: evenly.clamp(minSlotHeight, double.infinity),
        topInset: 0,
      );
    }
    final packedHeight = tagCount * maxSlotHeight;
    return (
      fillHeight: false,
      slotHeight: maxSlotHeight,
      topInset: ((availableHeight - packedHeight) / 2).clamp(
        0.0,
        double.infinity,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (tags.length < 2) {
      return const SizedBox.shrink();
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final layout = layoutFor(
          tagCount: tags.length,
          availableHeight: constraints.maxHeight,
        );

        void selectFromPosition(Offset localPosition, bool dragging) {
          final index = (localPosition.dy / layout.slotHeight).floor().clamp(
            0,
            tags.length - 1,
          );
          if (dragging) {
            onDragSelect(index);
          } else {
            onSelect(index);
          }
        }

        final column = Column(
          mainAxisSize: layout.fillHeight ? MainAxisSize.max : MainAxisSize.min,
          children: [
            for (var index = 0; index < tags.length; index++)
              layout.fillHeight
                  ? Expanded(
                      child: _IndexTag(
                        tag: tags[index],
                        selected: index == activeIndex,
                      ),
                    )
                  : SizedBox(
                      height: layout.slotHeight,
                      width: double.infinity,
                      child: _IndexTag(
                        tag: tags[index],
                        selected: index == activeIndex,
                      ),
                    ),
          ],
        );

        final detector = GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (details) =>
              selectFromPosition(details.localPosition, false),
          onVerticalDragStart: (details) =>
              selectFromPosition(details.localPosition, true),
          onVerticalDragUpdate: (details) =>
              selectFromPosition(details.localPosition, true),
          onVerticalDragEnd: (_) => onDragEnd(),
          onVerticalDragCancel: onDragEnd,
          child: column,
        );

        if (layout.fillHeight) {
          return detector;
        }

        return Align(alignment: Alignment.center, child: detector);
      },
    );
  }
}

class _IndexTag extends StatelessWidget {
  const _IndexTag({required this.tag, required this.selected});

  final String tag;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOutCubic,
        width: selected ? 20 : 14,
        height: selected ? 20 : 14,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? scheme.primary : Colors.transparent,
          shape: BoxShape.circle,
        ),
        child: Text(
          tag,
          textAlign: TextAlign.center,
          style: theme.textTheme.labelSmall?.copyWith(
            color: selected ? scheme.onPrimary : scheme.onSurfaceVariant,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            fontSize: 11,
            height: 1,
          ),
        ),
      ),
    );
  }
}

class _IndexBubble extends StatelessWidget {
  const _IndexBubble({required this.tag, this.size = 44});

  final String tag;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.primary,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: scheme.shadow.withValues(alpha: .16),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: SizedBox(
        width: size,
        height: size,
        child: Center(
          child: Text(
            tag,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: scheme.onPrimary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

class _CollapsingAddContactButton extends StatelessWidget {
  const _CollapsingAddContactButton({
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
      label: 'Add contact',
      child: Tooltip(
        message: 'Add contact',
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeInOutCubic,
          width: expanded ? 148 : 56,
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
                  Icon(AppIcons.add, color: scheme.onPrimary),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 260),
                    curve: Curves.easeInOutCubic,
                    child: expanded
                        ? Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: Text(
                              'Add contact',
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

class _ContactTile extends ConsumerWidget {
  const _ContactTile({
    required this.contact,
    required this.onTap,
    required this.onCall,
    required this.onMessage,
    super.key,
  });

  final Contact contact;
  final VoidCallback onTap;
  final VoidCallback onCall;
  final VoidCallback onMessage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final company = contact.company?.trim();
    final subtitle = company?.isNotEmpty == true
        ? company!
        : contact.phoneNumber;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.only(left: 2, right: 2),
          child: Row(
            children: [
              _ContactAvatar(contact: contact, radius: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      contact.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyLarge,
                    ),
                    if (subtitle.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: company == null
                            ? AppTheme.numberStyle(theme.textTheme.bodyMedium)
                            : theme.textTheme.bodyMedium,
                      ),
                    ],
                  ],
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'Call ${contact.displayName}',
                onPressed: onCall,
                icon: const Icon(AppIcons.call),
              ),
              if (isCarrierMessagingEnabled(
                ref.watch(sessionControllerProvider).value?.carrierMessaging,
              ))
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Message ${contact.displayName}',
                  onPressed: onMessage,
                  icon: const Icon(AppIcons.messages),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ContactAvatar extends StatelessWidget {
  const _ContactAvatar({
    required this.contact,
    this.radius = 22,
    this.highResolution = false,
  });

  final Contact contact;
  final double radius;
  final bool highResolution;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final photo = contact.photo;
    final decodeSize = highResolution
        ? (radius * 4).round().clamp(128, 512)
        : (radius * 3).round().clamp(48, 128);
    final wellColor = highResolution
        ? AppTheme.sheetControlBackground(theme.brightness)
        : AppTheme.avatarBackground(theme.brightness);
    return CircleAvatar(
      radius: radius,
      backgroundColor: wellColor,
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
              _initials(contact.displayName),
              style: TextStyle(
                fontSize: radius * .62,
                color: AppTheme.avatarForeground,
                fontWeight: FontWeight.w700,
              ),
            )
          : null,
    );
  }
}

class _ContactDetailsSheet extends StatefulWidget {
  const _ContactDetailsSheet({
    required this.contact,
    required this.loadContact,
    required this.onEdit,
    required this.onCall,
    required this.onMessage,
  });

  final Contact contact;
  final Future<Contact?> Function() loadContact;
  final Future<String?> Function() onEdit;
  final Future<void> Function(Contact contact) onCall;
  final Future<void> Function(Contact contact) onMessage;

  @override
  State<_ContactDetailsSheet> createState() => _ContactDetailsSheetState();
}

class _ContactDetailsSheetState extends State<_ContactDetailsSheet> {
  late Future<Contact?> _loadFuture;
  var _editing = false;

  @override
  void initState() {
    super.initState();
    _loadFuture = widget.loadContact();
  }

  Future<void> _editContact() async {
    if (_editing) return;
    setState(() => _editing = true);
    try {
      await widget.onEdit();
      if (!mounted) return;
      // Native editor may return null even after a save; always reload.
      setState(() => _loadFuture = widget.loadContact());
    } finally {
      if (mounted) setState(() => _editing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * .88,
      child: FutureBuilder<Contact?>(
        future: _loadFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return _ContactDetailsLoading(contact: widget.contact);
          }
          final fullContact = snapshot.data;
          if (snapshot.hasError || fullContact == null) {
            return const Center(
              child: EmptyState(
                icon: AppIcons.contact,
                title: 'Contact unavailable',
                message: 'This contact may have been removed from the phone.',
              ),
            );
          }
          return _ContactDetails(
            contact: fullContact,
            editing: _editing,
            onEdit: _editContact,
            onCall: () {
              widget.onCall(fullContact);
            },
            onMessage: () {
              widget.onMessage(fullContact);
            },
          );
        },
      ),
    );
  }
}

class _ContactDetailsLoading extends StatelessWidget {
  const _ContactDetailsLoading({required this.contact});

  final Contact contact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
      child: Column(
        children: [
          const SizedBox(height: 40),
          _ContactAvatar(contact: contact, radius: 52, highResolution: true),
          const SizedBox(height: 16),
          Text(
            contact.displayName,
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 28),
          const CircularProgressIndicator(),
        ],
      ),
    );
  }
}

class _ContactDetails extends ConsumerWidget {
  const _ContactDetails({
    required this.contact,
    required this.editing,
    required this.onEdit,
    required this.onCall,
    required this.onMessage,
  });

  final Contact contact;
  final bool editing;
  final VoidCallback onEdit;
  final VoidCallback onCall;
  final VoidCallback onMessage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final quickDialEntries = ref.watch(quickDialProvider).value ?? const [];
    final quickDialEntry = _quickDialEntryForContact(quickDialEntries, contact);
    final inQuickDial = quickDialEntry != null;
    final canFavorite = contact.dialablePhones.isNotEmpty;
    final primaryNumber = contact.phoneNumber.trim();
    final canMessage = isCarrierMessagingEnabled(
      ref.watch(sessionControllerProvider).value?.carrierMessaging,
    );

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Column(
              children: [
                Row(
                  children: [
                    IconButton(
                      tooltip: inQuickDial
                          ? 'Remove from Quick Dial'
                          : 'Add to Quick Dial',
                      onPressed: !canFavorite || editing
                          ? null
                          : () => _toggleQuickDial(
                              context,
                              ref,
                              quickDialEntry: quickDialEntry,
                            ),
                      icon: Icon(
                        inQuickDial ? AppIcons.starFilled : AppIcons.star,
                        color: inQuickDial
                            ? AppTheme.swiftRed
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: editing ? 'Opening…' : 'Edit',
                      onPressed: editing ? null : onEdit,
                      icon: editing
                          ? SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: theme.colorScheme.primary,
                              ),
                            )
                          : Icon(
                              AppIcons.edit,
                              color: theme.colorScheme.primary,
                            ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                _ContactAvatar(
                  contact: contact,
                  radius: 52,
                  highResolution: true,
                ),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    contact.displayName,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (contact.company?.isNotEmpty == true) ...[
                  const SizedBox(height: 6),
                  Text(
                    contact.company!,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                if (primaryNumber.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    primaryNumber,
                    textAlign: TextAlign.center,
                    style: AppTheme.numberStyle(
                      theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 22),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _ContactDetailAction(
                      icon: AppIcons.call,
                      label: 'Call',
                      onPressed: onCall,
                    ),
                    if (canMessage) ...[
                      const SizedBox(width: 28),
                      _ContactDetailAction(
                        icon: AppIcons.messages,
                        label: 'Message',
                        onPressed: onMessage,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 20),
                Divider(
                  height: 1,
                  color: theme.colorScheme.outlineVariant.withValues(
                    alpha: 0.55,
                  ),
                ),
              ],
            ),
          ),
        ),
        for (final section in contact.details)
          SliverToBoxAdapter(child: _ContactDetailSection(section: section)),
        const SliverToBoxAdapter(child: SizedBox(height: 28)),
      ],
    );
  }

  Future<void> _toggleQuickDial(
    BuildContext context,
    WidgetRef ref, {
    required QuickDialEntry? quickDialEntry,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    if (quickDialEntry != null) {
      try {
        await ref.read(quickDialProvider.notifier).remove(quickDialEntry.id);
        messenger.showSnackBar(
          const SnackBar(content: Text('Removed from Quick Dial.')),
        );
      } catch (_) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Could not update Quick Dial.')),
        );
      }
      return;
    }

    final phones = contact.dialablePhones;
    if (phones.isEmpty) return;

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
    if (number == null || number.isEmpty) return;

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
      messenger.showSnackBar(
        const SnackBar(content: Text('Added to Quick Dial.')),
      );
    } on QuickDialDuplicateException {
      messenger.showSnackBar(
        SnackBar(content: Text('$number is already in Quick Dial.')),
      );
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not add to Quick Dial.')),
      );
    }
  }
}

class _ContactDetailAction extends StatelessWidget {
  const _ContactDetailAction({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        IconButton.filledTonal(
          onPressed: onPressed,
          icon: Icon(icon),
          style: IconButton.styleFrom(
            foregroundColor: theme.colorScheme.primary,
            backgroundColor: AppTheme.sheetControlBackground(theme.brightness),
            disabledBackgroundColor: AppTheme.sheetControlBackground(
              theme.brightness,
            ),
            minimumSize: const Size(56, 56),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _ContactDetailSection extends StatelessWidget {
  const _ContactDetailSection({required this.section});

  final ContactDetailSection section;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            section.title,
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(height: 4),
          for (var index = 0; index < section.items.length; index++) ...[
            if (index > 0)
              Divider(
                height: 1,
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.45),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    section.items[index].label,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 4),
                  SelectableText(
                    section.items[index].value,
                    style: theme.textTheme.bodyLarge,
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

QuickDialEntry? _quickDialEntryForContact(
  List<QuickDialEntry> entries,
  Contact contact,
) {
  final bySource = entries.where(
    (entry) =>
        entry.source == QuickDialSource.contact && entry.sourceId == contact.id,
  );
  if (bySource.isNotEmpty) {
    return bySource.first;
  }

  final numbers = {
    for (final phone in contact.dialablePhones)
      phone.number.trim().replaceAll(RegExp(r'\s+'), ''),
  }..removeWhere((value) => value.isEmpty);
  if (numbers.isEmpty) return null;

  for (final entry in entries) {
    final normalized = entry.number.trim().replaceAll(RegExp(r'\s+'), '');
    if (numbers.contains(normalized)) {
      return entry;
    }
  }
  return null;
}

class _EmptyContacts extends StatelessWidget {
  const _EmptyContacts({required this.query, required this.totalCount});

  final String query;
  final int totalCount;

  @override
  Widget build(BuildContext context) {
    final searching = query.isNotEmpty && totalCount > 0;
    return AppCard(
      padding: const EdgeInsets.all(12),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 340),
          child: EmptyState(
            framed: false,
            icon: AppIcons.navContacts,
            title: searching ? 'No matching contacts' : 'No phone contacts',
            message: searching
                ? 'Try a different name, number, or company.'
                : 'Contacts saved on this phone will appear here automatically.',
          ),
        ),
      ),
    );
  }
}

class _ContactsError extends StatelessWidget {
  const _ContactsError({
    required this.error,
    required this.onRetry,
    required this.onOpenSettings,
  });

  final Object error;
  final VoidCallback onRetry;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final accessError = error is ContactsAccessException;
    final unsupported = error is UnsupportedContactsPlatformException;
    final canOpenSettings =
        accessError && (error as ContactsAccessException).canOpenSettings;
    return AppCard(
      padding: const EdgeInsets.all(12),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: EmptyState(
            framed: false,
            icon: AppIcons.navContacts,
            title: unsupported
                ? 'Phone contacts unavailable'
                : accessError
                ? 'Allow contacts access'
                : 'Could not load contacts',
            message: unsupported
                ? 'Phone contacts are available in the Android and iOS app.'
                : accessError
                ? 'VoipCloud uses contact access to show the contacts already saved on this phone.'
                : 'Check the device and try again.',
            action: FilledButton.icon(
              onPressed: canOpenSettings ? onOpenSettings : onRetry,
              icon: Icon(
                canOpenSettings ? AppIcons.navSettings : AppIcons.refresh,
              ),
              label: Text(canOpenSettings ? 'Open settings' : 'Try again'),
            ),
          ),
        ),
      ),
    );
  }
}

String _initials(String name) {
  final words = name
      .trim()
      .split(RegExp(r'\s+'))
      .where((word) => word.isNotEmpty)
      .toList();
  if (words.isEmpty) return '?';
  if (words.length == 1) return words.first[0].toUpperCase();
  return '${words.first[0]}${words.last[0]}'.toUpperCase();
}

String _sectionTag(Contact contact, _ContactSort sort) {
  final value = switch (sort) {
    _ContactSort.firstName => contact.firstName,
    _ContactSort.lastName => contact.lastName,
    _ContactSort.displayName => contact.displayName,
    _ContactSort.company => contact.company,
  };
  final text = (value?.trim().isNotEmpty == true ? value : contact.displayName)
      ?.trim();
  if (text == null || text.isEmpty) {
    return '#';
  }

  final firstCharacter = text[0].toUpperCase();
  return RegExp(r'[A-Z]').hasMatch(firstCharacter) ? firstCharacter : '#';
}

enum _ContactSort { firstName, lastName, displayName, company }

extension on _ContactSort {
  String get label => switch (this) {
    _ContactSort.firstName => 'First name',
    _ContactSort.lastName => 'Last name',
    _ContactSort.displayName => 'Display name',
    _ContactSort.company => 'Company',
  };
}
