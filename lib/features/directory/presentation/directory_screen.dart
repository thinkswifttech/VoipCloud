import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/route_names.dart';
import '../../../app/theme/app_theme.dart';
import '../../../core/errors/app_exception.dart';
import '../../../features/calls/presentation/call_session_providers.dart';
import '../../../features/dialer/presentation/dialer_controller.dart';
import '../../../features/session/presentation/session_controller.dart';
import '../../../shared/icons/app_icons.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/page_content.dart';
import '../../../voip/platform/voip_platform_channel.dart';
import '../data/dialog_presence_parser.dart';
import '../data/directory_presence.dart';
import '../domain/directory_entry.dart';
import 'directory_providers.dart';

enum _DirectoryTab { company, external }

enum _DirectorySort { displayName, company, extension }

extension on _DirectorySort {
  String labelFor(_DirectoryTab tab) => switch (this) {
    _DirectorySort.displayName => 'Display name',
    _DirectorySort.company => 'Company',
    _DirectorySort.extension =>
      tab == _DirectoryTab.external ? 'Phone number' : 'Extension',
  };
}

List<_DirectorySort> _sortOptionsFor(_DirectoryTab tab) {
  return switch (tab) {
    _DirectoryTab.company => const [
      _DirectorySort.displayName,
      _DirectorySort.extension,
    ],
    _DirectoryTab.external => const [
      _DirectorySort.displayName,
      _DirectorySort.company,
      _DirectorySort.extension,
    ],
  };
}

class DirectoryScreen extends ConsumerStatefulWidget {
  const DirectoryScreen({super.key});

  @override
  ConsumerState<DirectoryScreen> createState() => _DirectoryScreenState();
}

class _DirectoryScreenState extends ConsumerState<DirectoryScreen> {
  final _searchController = TextEditingController();
  final _presencePlatform = const VoipPlatformChannel();
  final Map<String, DirectoryPresence> _dialogPresence = {};
  final Map<String, DirectoryPresence> _availabilityPresence = {};
  StreamSubscription<Map<String, dynamic>>? _presenceSubscription;
  String _presenceSubscriptionKey = '';
  String _query = '';
  _DirectoryTab _tab = _DirectoryTab.company;
  _DirectorySort _sort = _DirectorySort.displayName;
  bool _ascending = true;
  List<DirectoryEntry>? _lastInput;
  List<DirectoryEntry>? _lastVisible;
  String? _lastQuery;
  _DirectoryTab? _lastTab;
  _DirectorySort? _lastSort;
  bool? _lastAscending;

  @override
  void initState() {
    super.initState();
    _presenceSubscription = _presencePlatform.presenceEvents().listen(
      _handlePresenceEvent,
      onError: (_) {},
    );
  }

  @override
  void dispose() {
    unawaited(_presenceSubscription?.cancel());
    unawaited(_presencePlatform.stopPresenceSubscriptions().catchError((_) {}));
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final directory = ref.watch(directoryProvider);
    final transferMode = ref.watch(callTransferModeProvider);

    ref.listen<bool>(callTransferModeProvider, (previous, next) {
      if (next && _tab != _DirectoryTab.company) {
        setState(() {
          _tab = _DirectoryTab.company;
          if (!_sortOptionsFor(_tab).contains(_sort)) {
            _sort = _DirectorySort.displayName;
          }
        });
      }
    });

    return PageContent(
      maxWidth: 680,
      scrollable: false,
      safeAreaBottom: false,
      padding: const EdgeInsets.fromLTRB(20, 12, 8, 0),
      child: directory.when(
        data: (items) {
          _schedulePresenceSubscriptions(items);
          final displayedItems = items
              .map(_withLivePresence)
              .toList(growable: false);
          final hasExternalContacts = displayedItems.any(
            (entry) => entry.isExternal,
          );
          final effectiveTab = transferMode || !hasExternalContacts
              ? _DirectoryTab.company
              : _tab;
          if (!transferMode &&
              !hasExternalContacts &&
              _tab != _DirectoryTab.company) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted || _tab == _DirectoryTab.company) return;
              setState(() {
                _tab = _DirectoryTab.company;
                if (!_sortOptionsFor(_tab).contains(_sort)) {
                  _sort = _DirectorySort.displayName;
                }
              });
            });
          }
          return _DirectoryPanel(
            entries: _visibleEntries(displayedItems, forcedTab: effectiveTab),
            totalInTab: _tabEntries(
              displayedItems,
              forcedTab: effectiveTab,
            ).length,
            tab: effectiveTab,
            showExternalTab: hasExternalContacts && !transferMode,
            transferMode: transferMode,
            searchController: _searchController,
            query: _query,
            sort: _sort,
            ascending: _ascending,
            onTabChanged: transferMode || !hasExternalContacts
                ? null
                : (tab) => setState(() {
                    _tab = tab;
                    if (!_sortOptionsFor(tab).contains(_sort)) {
                      _sort = _DirectorySort.displayName;
                    }
                  }),
            onQueryChanged: (value) => setState(() => _query = value.trim()),
            onSortChanged: (value) => setState(() => _sort = value),
            onToggleDirection: () => setState(() => _ascending = !_ascending),
            onRefresh: () => ref.read(directoryProvider.notifier).refresh(),
            onOpen: _openEntry,
            onCall: _callEntry,
            onTransfer: _transferEntry,
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: EmptyState(
              framed: false,
              icon: AppIcons.navDirectory,
              title: 'Directory unavailable',
              message: 'We could not load company extensions right now.',
              action: OutlinedButton.icon(
                onPressed: () => ref.read(directoryProvider.notifier).refresh(),
                icon: const Icon(AppIcons.refresh, size: AppIconSize.sm),
                label: const Text('Try again'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _schedulePresenceSubscriptions(List<DirectoryEntry> entries) {
    final extensions =
        entries
            .where((entry) => entry.isCompany)
            .expand((entry) => entry.numbers)
            .map((number) => number.trim())
            .where((number) => RegExp(r'^\d{2,8}$').hasMatch(number))
            .toSet()
            .toList()
          ..sort();
    final key = extensions.join(',');
    if (key == _presenceSubscriptionKey) return;
    _presenceSubscriptionKey = key;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || key != _presenceSubscriptionKey) return;
      if (_dialogPresence.isNotEmpty || _availabilityPresence.isNotEmpty) {
        setState(() {
          _dialogPresence.clear();
          _availabilityPresence.clear();
        });
      }
      try {
        if (extensions.isEmpty) {
          await _presencePlatform.stopPresenceSubscriptions();
        } else {
          await _presencePlatform.startPresenceSubscriptions(extensions);
        }
      } on Object {
        // Presence is supplementary; unsupported platforms still show contacts.
      }
    });
  }

  void _handlePresenceEvent(Map<String, dynamic> event) {
    if (!mounted) return;
    final extension = '${event['extension'] ?? ''}'.trim();
    if (extension.isEmpty) return;
    final update = parseSipPresenceEvent(event);
    if (update == null) return;
    final target = update.package == SipPresencePackage.dialog
        ? _dialogPresence
        : _availabilityPresence;
    if (target[extension] == update.presence) return;
    setState(() => target[extension] = update.presence);
  }

  DirectoryEntry _withLivePresence(DirectoryEntry entry) {
    if (!entry.isCompany) return entry;
    final states = entry.numbers
        .map((number) => _dialogPresence[number.trim()])
        .whereType<DirectoryPresence>()
        .toList(growable: false);
    final availabilityStates = entry.numbers
        .map((number) => _availabilityPresence[number.trim()])
        .whereType<DirectoryPresence>()
        .toList(growable: false);
    if (states.isEmpty && availabilityStates.isEmpty) return entry;
    final presence = directoryPresenceWithRegistration(
      entry: entry,
      liveStates: states,
      availabilityStates: availabilityStates,
    );
    return entry.copyWith(presence: presence);
  }

  List<DirectoryEntry> _tabEntries(
    List<DirectoryEntry> entries, {
    _DirectoryTab? forcedTab,
  }) {
    final tab =
        forcedTab ??
        (ref.read(callTransferModeProvider) ? _DirectoryTab.company : _tab);
    return entries.where((entry) {
      return switch (tab) {
        _DirectoryTab.company => entry.isCompany,
        _DirectoryTab.external => entry.isExternal,
      };
    }).toList();
  }

  List<DirectoryEntry> _visibleEntries(
    List<DirectoryEntry> entries, {
    _DirectoryTab? forcedTab,
  }) {
    final effectiveTab =
        forcedTab ??
        (ref.read(callTransferModeProvider) ? _DirectoryTab.company : _tab);
    if (identical(_lastInput, entries) &&
        _lastQuery == _query &&
        _lastTab == effectiveTab &&
        _lastSort == _sort &&
        _lastAscending == _ascending) {
      return _lastVisible!;
    }

    final visible = _filteredAndSorted(
      _tabEntries(entries, forcedTab: effectiveTab),
      forcedTab: effectiveTab,
    );
    _lastInput = entries;
    _lastVisible = visible;
    _lastQuery = _query;
    _lastTab = effectiveTab;
    _lastSort = _sort;
    _lastAscending = _ascending;
    return visible;
  }

  List<DirectoryEntry> _filteredAndSorted(
    List<DirectoryEntry> entries, {
    _DirectoryTab? forcedTab,
  }) {
    final query = _query.toLowerCase();
    final effectiveTab =
        forcedTab ??
        (ref.read(callTransferModeProvider) ? _DirectoryTab.company : _tab);
    final filtered = query.isEmpty
        ? entries.toList()
        : entries.where((entry) {
            final matchesNameOrNumber =
                entry.displayName.toLowerCase().contains(query) ||
                entry.numbers.any(
                  (number) => number.toLowerCase().contains(query),
                );
            if (effectiveTab != _DirectoryTab.external) {
              return matchesNameOrNumber ||
                  entry.teams.any((team) => team.toLowerCase().contains(query));
            }
            return matchesNameOrNumber ||
                entry.company.toLowerCase().contains(query);
          }).toList();

    filtered.sort((a, b) {
      final aValue = _sortValue(a);
      final bValue = _sortValue(b);
      final result = aValue.compareTo(bValue);
      if (result != 0) {
        return _ascending ? result : -result;
      }
      final fallback = a.displayName.toLowerCase().compareTo(
        b.displayName.toLowerCase(),
      );
      return _ascending ? fallback : -fallback;
    });
    return filtered;
  }

  String _sortValue(DirectoryEntry entry) {
    return switch (_sort) {
      _DirectorySort.displayName => entry.displayName.trim().toLowerCase(),
      _DirectorySort.company => entry.company.trim().toLowerCase(),
      _DirectorySort.extension => entry.extension.trim().toLowerCase(),
    };
  }

  Future<void> _openEntry(DirectoryEntry entry) async {
    final transferMode = ref.read(callTransferModeProvider);
    final destination = await _selectNumber(
      entry,
      action: transferMode ? _NumberAction.transfer : _NumberAction.call,
      alwaysShow: true,
    );
    if (destination == null || !mounted) return;
    if (transferMode) {
      await _transferEntry(entry, selectedNumber: destination);
    } else {
      _dialNumber(destination);
    }
  }

  Future<void> _callEntry(DirectoryEntry entry) async {
    final destination = await _selectNumber(entry, action: _NumberAction.call);
    if (destination == null || !mounted) return;
    _dialNumber(destination);
  }

  void _dialNumber(String destination) {
    ref.read(dialerControllerProvider.notifier)
      ..clear()
      ..append(destination);
    context.go(RoutePaths.dialer);
  }

  Future<void> _transferEntry(
    DirectoryEntry entry, {
    String? selectedNumber,
  }) async {
    final destination =
        selectedNumber ??
        await _selectNumber(entry, action: _NumberAction.transfer);
    if (destination == null || !mounted) return;
    final call = ref.read(activeCallProvider).value;
    if (call == null || !isInCallUiCall(call)) {
      ref.read(callTransferModeProvider.notifier).clear();
      return;
    }

    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        final theme = Theme.of(sheetContext);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Transfer call?', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                Text(
                  'Blind transfer to ${entry.displayName} · $destination',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: () => Navigator.of(sheetContext).pop(true),
                  icon: const Icon(AppIcons.callForward, size: AppIconSize.sm),
                  label: const Text('Transfer'),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => Navigator.of(sheetContext).pop(false),
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (confirmed != true || !mounted) {
      return;
    }

    try {
      await ref
          .read(sipServiceProvider)
          .transferCall(callId: call.id, destination: destination);
      if (!mounted) return;
      ref.read(callTransferModeProvider.notifier).clear();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Transferring to ${entry.displayName}…')),
      );
      context.go(RoutePaths.dialer);
    } catch (error) {
      if (!mounted) return;
      final message = error is AppException
          ? error.userMessage
          : 'Transfer could not be completed.';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<String?> _selectNumber(
    DirectoryEntry entry, {
    required _NumberAction action,
    bool alwaysShow = false,
  }) async {
    if (!alwaysShow && entry.numbers.length == 1) {
      return entry.numbers.first;
    }
    return showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                entry.displayName,
                style: Theme.of(sheetContext).textTheme.titleLarge,
              ),
              if (entry.company.trim().isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  entry.company,
                  style: Theme.of(sheetContext).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(sheetContext).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              if (entry.isCompany && entry.teams.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  entry.teams.length == 1 ? 'Team' : 'Teams',
                  style: Theme.of(sheetContext).textTheme.labelMedium?.copyWith(
                    color: Theme.of(sheetContext).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 4),
                for (final team in entry.teams)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Text(team),
                  ),
              ],
              const SizedBox(height: 12),
              for (final number in entry.numbers)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    number,
                    style: AppTheme.numberStyle(
                      Theme.of(sheetContext).textTheme.bodyLarge,
                    ),
                  ),
                  trailing: IconButton(
                    tooltip: action == _NumberAction.call
                        ? 'Call $number'
                        : 'Transfer to $number',
                    onPressed: () => Navigator.pop(sheetContext, number),
                    icon: Icon(
                      action == _NumberAction.call
                          ? AppIcons.call
                          : AppIcons.callForward,
                    ),
                  ),
                  onTap: () => Navigator.pop(sheetContext, number),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _NumberAction { call, transfer }

class _DirectoryPanel extends StatefulWidget {
  const _DirectoryPanel({
    required this.entries,
    required this.totalInTab,
    required this.tab,
    required this.showExternalTab,
    required this.transferMode,
    required this.searchController,
    required this.query,
    required this.sort,
    required this.ascending,
    required this.onTabChanged,
    required this.onQueryChanged,
    required this.onSortChanged,
    required this.onToggleDirection,
    required this.onRefresh,
    required this.onOpen,
    required this.onCall,
    required this.onTransfer,
  });

  final List<DirectoryEntry> entries;
  final int totalInTab;
  final _DirectoryTab tab;
  final bool showExternalTab;
  final bool transferMode;
  final TextEditingController searchController;
  final String query;
  final _DirectorySort sort;
  final bool ascending;
  final ValueChanged<_DirectoryTab>? onTabChanged;
  final ValueChanged<String> onQueryChanged;
  final ValueChanged<_DirectorySort> onSortChanged;
  final VoidCallback onToggleDirection;
  final Future<void> Function() onRefresh;
  final ValueChanged<DirectoryEntry> onOpen;
  final ValueChanged<DirectoryEntry> onCall;
  final ValueChanged<DirectoryEntry> onTransfer;

  @override
  State<_DirectoryPanel> createState() => _DirectoryPanelState();
}

class _DirectoryPanelState extends State<_DirectoryPanel> {
  static const _sectionHeaderHeight = 28.0;
  static const _companyTileHeight = 84.0;
  static const _externalTileHeight = 84.0;
  static const _listBottomPadding = 28.0;
  static const _indexBarWidth = 24.0;

  final _scrollController = ScrollController();
  final _activeSectionIndex = ValueNotifier<int>(0);
  final _showIndexBubble = ValueNotifier<bool>(false);
  List<_DirectoryListEntry> _entries = const [];
  List<_DirectorySection> _sections = const [];
  List<String> _sectionTags = const [];
  bool _indexDragging = false;
  bool _showSortFilters = false;
  Timer? _hideIndexBubbleTimer;

  double get _tileHeight => widget.tab == _DirectoryTab.external
      ? _externalTileHeight
      : _companyTileHeight;

  @override
  void initState() {
    super.initState();
    _rebuildEntries();
    _scrollController.addListener(_syncActiveSection);
  }

  @override
  void didUpdateWidget(covariant _DirectoryPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final resetScroll =
        oldWidget.sort != widget.sort ||
        oldWidget.ascending != widget.ascending ||
        oldWidget.tab != widget.tab ||
        !_sameEntryOrder(oldWidget.entries, widget.entries);
    if (!identical(oldWidget.entries, widget.entries) ||
        oldWidget.sort != widget.sort ||
        oldWidget.ascending != widget.ascending ||
        oldWidget.tab != widget.tab) {
      _rebuildEntries();
      if (resetScroll) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _scrollController.hasClients) {
            _scrollController.jumpTo(0);
          }
        });
      }
    }
  }

  bool _sameEntryOrder(
    List<DirectoryEntry> previous,
    List<DirectoryEntry> next,
  ) {
    if (previous.length != next.length) return false;
    for (var index = 0; index < previous.length; index++) {
      if (previous[index].id != next[index].id) return false;
    }
    return true;
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
      widget.sort == _DirectorySort.displayName && widget.ascending;

  void _rebuildEntries() {
    final entries = <_DirectoryListEntry>[];
    final sections = <_DirectorySection>[];
    var offset = 0.0;
    String? currentTag;

    for (final entry in widget.entries) {
      final tag = _sectionTag(entry, widget.sort);
      if (tag != currentTag) {
        currentTag = tag;
        sections.add(_DirectorySection(tag: tag, offset: offset));
        entries.add(_DirectoryListEntry.header(tag));
        offset += _sectionHeaderHeight;
      }
      entries.add(_DirectoryListEntry.item(entry));
      offset += _tileHeight;
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
      if (mounted) {
        _showIndexBubble.value = false;
      }
    });
  }

  double? _extentForIndex(int index, _) {
    if (index < 0 || index >= _entries.length) {
      return null;
    }
    return _entries[index].entry == null ? _sectionHeaderHeight : _tileHeight;
  }

  @override
  Widget build(BuildContext context) {
    final showIndex = _sectionTags.length > 1;

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
      child: Column(
        children: [
          if (widget.showExternalTab) ...[
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: SizedBox(
                width: double.infinity,
                child: SegmentedButton<_DirectoryTab>(
                  expandedInsets: EdgeInsets.zero,
                  showSelectedIcon: false,
                  style: SegmentedButton.styleFrom(
                    selectedBackgroundColor: Theme.of(
                      context,
                    ).colorScheme.primary,
                    selectedForegroundColor: Theme.of(
                      context,
                    ).colorScheme.onPrimary,
                    backgroundColor: Theme.of(context).colorScheme.surface,
                    foregroundColor: Theme.of(
                      context,
                    ).colorScheme.onSurfaceVariant,
                    side: BorderSide(
                      color: Theme.of(context).colorScheme.outline,
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                  ),
                  segments: const [
                    ButtonSegment(
                      value: _DirectoryTab.company,
                      label: Text('Company'),
                      icon: Icon(AppIcons.navDirectory, size: AppIconSize.sm),
                    ),
                    ButtonSegment(
                      value: _DirectoryTab.external,
                      label: Text('External'),
                      icon: Icon(AppIcons.cloud, size: AppIconSize.sm),
                    ),
                  ],
                  selected: {widget.tab},
                  onSelectionChanged: widget.onTabChanged == null
                      ? null
                      : (selection) {
                          if (selection.isNotEmpty) {
                            FocusManager.instance.primaryFocus?.unfocus();
                            widget.onTabChanged!(selection.first);
                          }
                        },
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: widget.searchController,
                    onChanged: widget.onQueryChanged,
                    textInputAction: TextInputAction.search,
                    onTapOutside: (_) =>
                        FocusManager.instance.primaryFocus?.unfocus(),
                    onSubmitted: (_) =>
                        FocusManager.instance.primaryFocus?.unfocus(),
                    decoration: InputDecoration(
                      hintText: widget.transferMode
                          ? 'Search who to transfer to'
                          : widget.tab == _DirectoryTab.external
                          ? 'Search name, company, or number'
                          : 'Search name or extension',
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
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: _showSortFilters
                ? Padding(
                    padding: const EdgeInsets.only(top: 10, right: 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<_DirectorySort>(
                            key: ValueKey('${widget.tab}-${widget.sort}'),
                            initialValue: widget.sort,
                            isExpanded: true,
                            decoration: const InputDecoration(
                              labelText: 'Sort by',
                            ),
                            items: _sortOptionsFor(widget.tab)
                                .map(
                                  (option) => DropdownMenuItem(
                                    value: option,
                                    child: Text(
                                      option.labelFor(widget.tab),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                )
                                .toList(),
                            onChanged: (value) {
                              if (value != null) {
                                widget.onSortChanged(value);
                              }
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
            child: widget.entries.isEmpty
                ? _DirectoryEmpty(
                    tab: widget.tab,
                    query: widget.query,
                    totalInTab: widget.totalInTab,
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
                                        keyboardDismissBehavior:
                                            ScrollViewKeyboardDismissBehavior
                                                .onDrag,
                                        cacheExtent: 960,
                                        addAutomaticKeepAlives: false,
                                        addRepaintBoundaries: false,
                                        itemExtentBuilder: _extentForIndex,
                                        padding: const EdgeInsets.only(
                                          bottom: _listBottomPadding,
                                        ),
                                        itemCount: _entries.length,
                                        itemBuilder: (context, index) {
                                          final item = _entries[index];
                                          final entry = item.entry;
                                          if (entry == null) {
                                            return _DirectorySectionHeader(
                                              tag: item.tag,
                                            );
                                          }
                                          return _DirectoryTile(
                                            key: ValueKey(entry.id),
                                            entry: entry,
                                            showCompany:
                                                widget.tab ==
                                                _DirectoryTab.external,
                                            transferMode: widget.transferMode,
                                            onOpen: () {
                                              FocusManager.instance.primaryFocus
                                                  ?.unfocus();
                                              widget.onOpen(entry);
                                            },
                                            onAction: () {
                                              FocusManager.instance.primaryFocus
                                                  ?.unfocus();
                                              if (widget.transferMode) {
                                                widget.onTransfer(entry);
                                              } else {
                                                widget.onCall(entry);
                                              }
                                            },
                                          );
                                        },
                                      ),
                                      Positioned(
                                        top: 0,
                                        left: 0,
                                        right: 0,
                                        child: ValueListenableBuilder<int>(
                                          valueListenable: _activeSectionIndex,
                                          builder: (context, activeIndex, _) {
                                            if (_sectionTags.isEmpty) {
                                              return const SizedBox.shrink();
                                            }
                                            return _StickyDirectorySectionHeader(
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
                                          return _DirectoryIndexBar(
                                            tags: _sectionTags,
                                            activeIndex: activeIndex,
                                            onSelect: (index) => _selectSection(
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
                                      if (!visible ||
                                          activeIndex < 0 ||
                                          activeIndex >= _sectionTags.length) {
                                        return const SizedBox.shrink();
                                      }
                                      final tag = _sectionTags[activeIndex];
                                      const bubbleSize = 44.0;
                                      final availableHeight =
                                          (constraints.maxHeight -
                                                  _listBottomPadding)
                                              .clamp(0.0, double.infinity);
                                      final layout =
                                          _DirectoryIndexBar.layoutFor(
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
                                        right: _indexBarWidth + 10,
                                        child: IgnorePointer(
                                          child: AnimatedOpacity(
                                            opacity: visible ? 1 : 0,
                                            duration: const Duration(
                                              milliseconds: 100,
                                            ),
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
    );
  }
}

String _sectionTag(DirectoryEntry entry, _DirectorySort sort) {
  final raw = switch (sort) {
    _DirectorySort.displayName => entry.displayName,
    _DirectorySort.company => entry.company,
    _DirectorySort.extension => entry.extension,
  }.trim();
  if (raw.isEmpty) {
    return '#';
  }
  final char = raw.substring(0, 1).toUpperCase();
  final code = char.codeUnitAt(0);
  if (code >= 65 && code <= 90) {
    return char;
  }
  return '#';
}

class _DirectoryListEntry {
  const _DirectoryListEntry._({required this.tag, this.entry});

  factory _DirectoryListEntry.header(String tag) =>
      _DirectoryListEntry._(tag: tag);

  factory _DirectoryListEntry.item(DirectoryEntry entry) =>
      _DirectoryListEntry._(tag: '', entry: entry);

  final String tag;
  final DirectoryEntry? entry;
}

class _DirectorySection {
  const _DirectorySection({required this.tag, required this.offset});

  final String tag;
  final double offset;
}

class _DirectorySectionHeader extends StatelessWidget {
  const _DirectorySectionHeader({required this.tag});

  final String tag;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: _DirectoryPanelState._sectionHeaderHeight,
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

class _StickyDirectorySectionHeader extends StatelessWidget {
  const _StickyDirectorySectionHeader({required this.tag});

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
      child: _DirectorySectionHeader(tag: tag),
    );
  }
}

class _DirectoryIndexBar extends StatelessWidget {
  const _DirectoryIndexBar({
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

  /// Layout metrics so the magnifier can stay aligned with the scrubber.
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

class _DirectoryTile extends StatelessWidget {
  const _DirectoryTile({
    super.key,
    required this.entry,
    required this.showCompany,
    required this.transferMode,
    required this.onOpen,
    required this.onAction,
  });

  final DirectoryEntry entry;
  final bool showCompany;
  final bool transferMode;
  final VoidCallback onOpen;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final companyLabel = entry.company.trim().isEmpty
        ? '—'
        : entry.company.trim();
    final teamLabel = switch (entry.teams.length) {
      0 => '',
      1 => entry.teams.first,
      _ => 'Multiple Teams',
    };
    final numberLabel = entry.hasMultipleNumbers
        ? '${entry.extension}  ·  ${entry.numbers.length - 1} more'
        : entry.extension;

    return InkWell(
      onTap: onOpen,
      child: SizedBox(
        height: showCompany
            ? _DirectoryPanelState._externalTileHeight
            : _DirectoryPanelState._companyTileHeight,
        child: Padding(
          padding: const EdgeInsets.only(right: 4),
          child: Row(
            children: [
              if (!showCompany) ...[
                _PresenceDot(presence: entry.presence),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyLarge,
                    ),
                    if (showCompany || teamLabel.isNotEmpty) ...[
                      const SizedBox(height: 1),
                      Text(
                        showCompany ? companyLabel : teamLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    const SizedBox(height: 2),
                    Text(
                      numberLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTheme.numberStyle(theme.textTheme.bodyMedium),
                    ),
                  ],
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: transferMode
                    ? entry.hasMultipleNumbers
                          ? 'Choose number to transfer to'
                          : 'Transfer to ${entry.extension}'
                    : entry.hasMultipleNumbers
                    ? 'Choose number to call'
                    : 'Call ${entry.extension}',
                onPressed: onAction,
                icon: Icon(transferMode ? AppIcons.callForward : AppIcons.call),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PresenceDot extends StatefulWidget {
  const _PresenceDot({required this.presence});

  final DirectoryPresence presence;

  @override
  State<_PresenceDot> createState() => _PresenceDotState();
}

class _PresenceDotState extends State<_PresenceDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ringingController;

  @override
  void initState() {
    super.initState();
    _ringingController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 650),
      lowerBound: .25,
      value: 1,
    );
    _updateAnimation();
  }

  @override
  void didUpdateWidget(covariant _PresenceDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.presence != widget.presence) _updateAnimation();
  }

  void _updateAnimation() {
    if (widget.presence == DirectoryPresence.ringing) {
      _ringingController.repeat(reverse: true);
    } else {
      _ringingController
        ..stop()
        ..value = 1;
    }
  }

  @override
  void dispose() {
    _ringingController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = switch (widget.presence) {
      DirectoryPresence.available => const Color(0xFF16A34A),
      DirectoryPresence.busy => const Color(0xFFDC2626),
      DirectoryPresence.ringing => const Color(0xFFF59E0B),
      DirectoryPresence.unregistered => const Color(0xFF9CA3AF),
      DirectoryPresence.unknown => const Color(0xFF9CA3AF),
    };
    final label = switch (widget.presence) {
      DirectoryPresence.available => 'Available',
      DirectoryPresence.busy => 'On a call',
      DirectoryPresence.ringing => 'Ringing',
      DirectoryPresence.unregistered => 'Not registered',
      DirectoryPresence.unknown => 'Status unavailable',
    };

    return Tooltip(
      message: label,
      child: Semantics(
        label: label,
        child: FadeTransition(
          opacity: _ringingController,
          child: Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: color.withValues(alpha: 0.28),
                  blurRadius: 4,
                  offset: const Offset(0, 1),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DirectoryEmpty extends StatelessWidget {
  const _DirectoryEmpty({
    required this.tab,
    required this.query,
    required this.totalInTab,
  });

  final _DirectoryTab tab;
  final String query;
  final int totalInTab;

  @override
  Widget build(BuildContext context) {
    final searching = query.isNotEmpty;
    final hasEntriesInTab = totalInTab > 0;

    final (title, message, icon) = switch ((tab, searching, hasEntriesInTab)) {
      (_DirectoryTab.company, true, false) => (
        'No company extensions',
        'Nothing here yet. Check back once your company directory is set up.',
        AppIcons.navDirectory,
      ),
      (_DirectoryTab.company, true, true) => (
        'No matching extensions',
        'Nothing matched “$query”. Try a different name or extension.',
        AppIcons.navDirectory,
      ),
      (_DirectoryTab.company, false, _) => (
        'No company extensions',
        'Nothing here yet. Check back once your company directory is set up.',
        AppIcons.navDirectory,
      ),
      (_DirectoryTab.external, true, false) => (
        'No external contacts',
        'External directory contacts will appear here when available.',
        AppIcons.navDirectory,
      ),
      (_DirectoryTab.external, true, true) => (
        'No matching contacts',
        'Nothing matched “$query”. Try a different name, company, or number.',
        AppIcons.navDirectory,
      ),
      (_DirectoryTab.external, false, _) => (
        'No external contacts',
        'External people and companies from your directory will appear here.',
        AppIcons.navDirectory,
      ),
    };

    // Match the right inset used by the search/tab chrome so the empty state
    // centers in the same visual column (PageContent leaves room for the A–Z rail).
    return LayoutBuilder(
      builder: (context, constraints) {
        return SizedBox(
          width: constraints.maxWidth,
          height: constraints.maxHeight,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.only(right: 12),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: EmptyState(
                  framed: false,
                  icon: icon,
                  title: title,
                  message: message,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
