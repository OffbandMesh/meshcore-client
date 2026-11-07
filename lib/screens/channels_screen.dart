import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:meshcore_open/storage/channel_message_store.dart';
import 'package:meshcore_open/utils/platform_info.dart';
import 'package:meshcore_open/widgets/app_bar.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../connector/meshcore_connector.dart';
import '../l10n/l10n.dart';
import '../services/app_settings_service.dart';
import '../services/ui_view_state_service.dart';
import '../models/channel.dart';
import '../models/community.dart';
import '../storage/community_store.dart';
import '../utils/dialog_utils.dart';
import '../utils/disconnect_navigation_mixin.dart';
import '../utils/route_transitions.dart';
import '../widgets/list_filter_widget.dart';
import '../widgets/empty_state.dart';
import '../widgets/qr_code_display.dart';
import '../widgets/app_shell.dart';
import '../widgets/channel_drawer_list.dart';
import '../widgets/sync_progress_overlay.dart';
import '../widgets/unread_badge.dart';
import '../widgets/channel_notify_mode.dart';
import '../widgets/radio_channel_notify.dart';
import '../widgets/radio_tone.dart';
import '../widgets/battery_optimization_banner.dart';
import '../helpers/channel_slot_ui.dart';
import '../helpers/snack_bar_builder.dart';
import 'channel_chat_screen.dart';
import 'community_qr_scanner_screen.dart';
import 'contacts_screen.dart';
import 'map_screen.dart';
import 'settings_screen.dart';

class ChannelsScreen extends StatefulWidget {
  const ChannelsScreen({super.key});

  @override
  State<ChannelsScreen> createState() => _ChannelsScreenState();
}

class _ChannelsScreenState extends State<ChannelsScreen>
    with DisconnectNavigationMixin {
  final TextEditingController _searchController = TextEditingController();
  final CommunityStore _communityStore = CommunityStore();
  final CommunityPskIndex _communityIndex = CommunityPskIndex();
  List<Community> _communities = [];
  Timer? _searchDebounce;

  ChannelMessageStore get _channelMessageStore => ChannelMessageStore();

  @override
  void initState() {
    super.initState();
    _searchController.text = context
        .read<UiViewStateService>()
        .channelsSearchText;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<MeshCoreConnector>().getChannels();
      _loadCommunities();
    });
  }

  Future<void> _loadCommunities() async {
    final connector = context.read<MeshCoreConnector>();
    _communityStore.setPublicKeyHex = connector.selfPublicKeyHex;
    final communities = await _communityStore.loadCommunities();
    if (mounted) {
      setState(() {
        _communities = communities;
        _communityIndex.initialize(communities);
      });
    }
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final connector = context.watch<MeshCoreConnector>();
    final viewState = context.watch<UiViewStateService>();

    final channelMessageStore = ChannelMessageStore();
    channelMessageStore.setPublicKeyHex = connector.selfPublicKeyHex;

    // Auto-navigate back to scanner if disconnected
    if (!checkConnectionAndNavigate(connector)) {
      return const SizedBox.shrink();
    }

    return AppShell(
      selectedIndex: 1,
      onDestinationSelected: (index) => _handleQuickSwitch(index, context),
      contactsUnreadCount: connector.getTotalContactsUnreadCount(),
      channelsUnreadCount: connector.getTotalChannelsUnreadCount(),
      drawerContent: ChannelDrawerList(
        onChannelSelected: (channel) => _openChannel(context, channel),
      ),
      onDisconnect: () => _disconnect(context),
      onSettings: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (context) => const SettingsScreen()),
      ),
      appBarBuilder: (context, pinned) => AppBar(
        // Top-level tab: no auto back-arrow. Hamburger when the panel is not
        // pinned; nothing when it is (panel is docked), so no dead arrow (#390).
        automaticallyImplyLeading: false,
        leading: pinned ? null : AppShell.drawerMenuButton(),
        title: AppBarTitle(context.l10n.channels_title),
        centerTitle: true,
        bottom: const SyncProgressAppBarBottom(),
        actions: [
          // Disconnect and Settings moved to the panel footer (#290); only
          // the screen-level Communities entry remains, and it already only
          // appears once a community has been joined.
          if (_communities.isNotEmpty)
            PopupMenuButton(
              itemBuilder: (context) => [
                PopupMenuItem(
                  child: Row(
                    children: [
                      const Icon(Icons.groups),
                      const SizedBox(width: 8),
                      Text(context.l10n.community_manageCommunities),
                    ],
                  ),
                  onTap: () => _showManageCommunitiesDialog(context),
                ),
              ],
              icon: const Icon(Icons.more_vert),
            ),
        ],
      ),
      body: BatteryOptimizationBanner(
        child: RefreshIndicator(
          onRefresh: () async {
            await context.read<MeshCoreConnector>().getChannels(force: true);
          },
          child: () {
            final channels = connector.channels;
            final waitingForFirstChannel =
                connector.isLoadingChannels && channels.isEmpty;

            // Only block the list while the first channel is actively loading.
            // If the initial sync aborts, show cached/partial channels instead
            // of trapping the user behind an idle spinner.
            if (waitingForFirstChannel) {
              return const Center(child: CircularProgressIndicator());
            }

            if (channels.isEmpty) {
              return LayoutBuilder(
                builder: (context, constraints) => SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight,
                    ),
                    child: EmptyState(
                      icon: Icons.tag,
                      title: context.l10n.channels_noChannelsConfigured,
                      action: FilledButton.icon(
                        onPressed: () => _addPublicChannel(context, connector),
                        icon: const Icon(Icons.public),
                        label: Text(context.l10n.channels_addPublicChannel),
                      ),
                    ),
                  ),
                ),
              );
            }

            final filteredChannels = _filterAndSortChannels(
              channels,
              connector,
              viewState,
            );

            return Column(
              children: [
                // #1062: persistent, undismissable while true. A slot the
                // radio never confirmed means its channel is unknown; a
                // 4-second toast is not an error surface (SAFELANE 6).
                if (connector.unconfirmedChannelSlots.isNotEmpty)
                  MaterialBanner(
                    backgroundColor: Theme.of(
                      context,
                    ).colorScheme.errorContainer,
                    content: Text(
                      context.l10n.channels_unconfirmedSlots(
                        connector.unconfirmedChannelSlots.toList().join(', '),
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () =>
                            unawaited(connector.getChannels(force: true)),
                        child: Text(context.l10n.channels_retrySync),
                      ),
                    ],
                  ),
                // #1060: the radio answered for these slots with erased
                // records. Undismissable: the radio has lost channels the
                // client still holds, and the only way out is to write them
                // back or accept the loss deliberately.
                if (connector.erasedChannelSlots.isNotEmpty)
                  MaterialBanner(
                    backgroundColor: Theme.of(
                      context,
                    ).colorScheme.errorContainer,
                    content: Text(
                      context.l10n.channels_erasedSlots(
                        connector.erasedChannelSlots.toList().join(', '),
                      ),
                    ),
                    actions: [
                      if (connector.canRestoreChannelsToRadio)
                        TextButton(
                          onPressed: () => unawaited(
                            _confirmRestoreChannels(context, connector),
                          ),
                          child: Text(context.l10n.channels_restoreToRadio),
                        ),
                    ],
                  ),
                if (connector.slotIdentityChanges.isNotEmpty)
                  MaterialBanner(
                    content: Text(
                      context.l10n.channels_slotIdentityChanged(
                        connector.slotIdentityChanges.join('; '),
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: connector.acknowledgeSlotIdentityChanges,
                        child: Text(context.l10n.common_dismiss),
                      ),
                    ],
                  ),
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: TextField(
                    controller: _searchController,
                    decoration: InputDecoration(
                      hintText: context.l10n.channels_searchChannels,
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (viewState.channelsSearchText.isNotEmpty)
                            IconButton(
                              icon: const Icon(Icons.clear),
                              onPressed: () {
                                _searchDebounce?.cancel();
                                _searchDebounce = null;
                                _searchController.clear();
                                context
                                    .read<UiViewStateService>()
                                    .setChannelsSearchText('');
                              },
                            ),
                          _buildFilterButton(viewState),
                        ],
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                    ),
                    onChanged: (value) {
                      _searchDebounce?.cancel();
                      _searchDebounce = Timer(
                        const Duration(milliseconds: 300),
                        () {
                          if (!mounted) return;
                          context
                              .read<UiViewStateService>()
                              .setChannelsSearchText(value);
                        },
                      );
                    },
                  ),
                ),
                Expanded(
                  child: filteredChannels.isEmpty
                      ? LayoutBuilder(
                          builder: (context, constraints) =>
                              SingleChildScrollView(
                                physics: const AlwaysScrollableScrollPhysics(),
                                child: ConstrainedBox(
                                  constraints: BoxConstraints(
                                    minHeight: constraints.maxHeight,
                                  ),
                                  child: Center(
                                    child: Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Icon(
                                          Icons.search_off,
                                          size: 64,
                                          color: Colors.grey[400],
                                        ),
                                        const SizedBox(height: 16),
                                        Text(
                                          context.l10n.channels_noChannelsFound,
                                          style: TextStyle(
                                            fontSize: 16,
                                            color: Colors.grey[600],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                        )
                      : (viewState.channelsSortOption ==
                                ChannelSortOption.manual &&
                            viewState.channelsSearchText.isEmpty)
                      ? ReorderableListView.builder(
                          padding: const EdgeInsets.only(
                            left: 16,
                            right: 16,
                            top: 8,
                            bottom: 88,
                          ),
                          buildDefaultDragHandles: false,
                          itemCount: filteredChannels.length,
                          onReorderItem: (oldIndex, newIndex) {
                            // onReorderItem already adjusts newIndex after the
                            // removed item, unlike the deprecated onReorder.
                            final reordered = List<Channel>.from(
                              filteredChannels,
                            );
                            final item = reordered.removeAt(oldIndex);
                            reordered.insert(newIndex, item);
                            unawaited(
                              connector.setChannelOrder(
                                reordered.map((c) => c.index).toList(),
                              ),
                            );
                          },
                          itemBuilder: (context, index) {
                            final channel = filteredChannels[index];
                            return _buildChannelTile(
                              context,
                              connector,
                              channelMessageStore,
                              channel,
                              showDragHandle: true,
                              dragIndex: index,
                            );
                          },
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.only(
                            left: 16,
                            right: 16,
                            top: 8,
                            bottom: 88,
                          ),
                          itemCount: filteredChannels.length,
                          itemBuilder: (context, index) {
                            final channel = filteredChannels[index];
                            return _buildChannelTile(
                              context,
                              connector,
                              channelMessageStore,
                              channel,
                            );
                          },
                        ),
                ),
              ],
            );
          }(),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showAddChannelDialog(context),
        tooltip: context.l10n.channels_addChannel,
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _buildChannelTile(
    BuildContext context,
    MeshCoreConnector connector,
    ChannelMessageStore channelMessageStore,
    Channel channel, {
    bool showDragHandle = false,
    int? dragIndex,
  }) {
    final unreadCount = connector.getUnreadCountForChannel(channel);

    // Determine icon and colors based on channel type
    IconData icon;
    Color iconColor;
    Color bgColor;
    final ChannelType channelType = Channel.getChannelType(
      channel,
      _communityIndex,
    );
    final bool isCommunityChannel = Channel.isCommunityChannel(channelType);
    switch (channelType) {
      case ChannelType.communityPublic:
        icon = Icons.groups;
        iconColor = Colors.purple;
        bgColor = Colors.purple.withValues(alpha: 0.2);
      case ChannelType.communityHashtag:
        icon = Icons.tag;
        iconColor = Colors.purple;
        bgColor = Colors.purple.withValues(alpha: 0.2);
      case ChannelType.public:
        icon = Icons.public;
        iconColor = Colors.green;
        bgColor = Colors.green.withValues(alpha: 0.2);
      case ChannelType.hashtag:
        icon = Icons.tag;
        iconColor = Colors.blue;
        bgColor = Colors.blue.withValues(alpha: 0.2);
      case ChannelType.private:
        icon = Icons.lock;
        iconColor = Colors.blue;
        bgColor = Colors.blue.withValues(alpha: 0.2);
    }

    return Card(
      key: ValueKey('channel_${channel.index}'),
      margin: const EdgeInsets.only(bottom: 12),
      child: GestureDetector(
        onSecondaryTapUp: PlatformInfo.isDesktop
            ? (_) => _showChannelActions(
                context,
                connector,
                channelMessageStore,
                channel,
              )
            : null,
        child: ListTile(
          dense: true,
          minVerticalPadding: 14,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12),
          visualDensity: const VisualDensity(vertical: -2),
          leading: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: CircleAvatar(
                  backgroundColor: bgColor,
                  child: Icon(icon, color: iconColor),
                ),
              ),
              if (isCommunityChannel)
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      color: Colors.purple,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Theme.of(context).cardColor,
                        width: 2,
                      ),
                    ),
                    child: const Icon(
                      Icons.people,
                      size: 8,
                      color: Colors.white,
                    ),
                  ),
                ),
            ],
          ),
          title: Text(
            channel.name.isEmpty
                ? context.l10n.channels_channelIndex(channel.index)
                : channel.name,
            style: const TextStyle(fontWeight: FontWeight.w500),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (unreadCount > 0) ...[
                UnreadBadge(count: unreadCount),
                const SizedBox(width: 4),
              ],
              if (showDragHandle && dragIndex != null)
                ReorderableDelayedDragStartListener(
                  index: dragIndex,
                  child: Icon(
                    Icons.drag_handle,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
          onTap: () async {
            final unread = connector.getUnreadCountForChannelIndex(
              channel.index,
            );
            connector.markChannelRead(channel.index);
            await Future.delayed(const Duration(milliseconds: 50));
            if (context.mounted) {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => ChannelChatScreen(
                    channel: channel,
                    initialUnreadCount: unread,
                  ),
                ),
              );
            }
          },
          onLongPress: () => _showChannelActions(
            context,
            connector,
            channelMessageStore,
            channel,
          ),
        ),
      ),
    );
  }

  void _showChannelActions(
    BuildContext context,
    MeshCoreConnector connector,
    ChannelMessageStore channelMessageStore,
    Channel channel,
  ) {
    final parentContext = context;
    final settingsService = context.read<AppSettingsService>();
    final notifyMode = settingsService.channelNotifyMode(
      devicePrefix: connector.selfPublicKeyHex,
      pskHex: channel.pskHex,
    );

    showModalBottomSheet(
      context: parentContext,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: Text(context.l10n.channels_editChannel),
                onTap: () async {
                  Navigator.pop(sheetContext);
                  await Future.delayed(const Duration(milliseconds: 100));
                  if (parentContext.mounted) {
                    _showEditChannelDialog(parentContext, connector, channel);
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.qr_code_2),
                title: Text(context.l10n.channels_shareQr),
                onTap: () async {
                  Navigator.pop(sheetContext);
                  await Future.delayed(const Duration(milliseconds: 100));
                  if (parentContext.mounted) {
                    _showChannelQrDialog(parentContext, channel);
                  }
                },
              ),
              ListTile(
                leading: Icon(channelNotifyModeIcon(notifyMode)),
                title: Text(context.l10n.channels_notifications),
                subtitle: Text(channelNotifyModeLabel(context, notifyMode)),
                onTap: () async {
                  Navigator.pop(sheetContext);
                  await Future.delayed(const Duration(milliseconds: 100));
                  if (parentContext.mounted) {
                    showChannelNotifyModeDialog(parentContext, channel);
                  }
                },
              ),
              // The radio's own sound setting for this channel (#544), named
              // apart from Notifications, which is the phone's. These are two
              // independent settings over two outputs: neither reads the other.
              // Gated on caps byte 2 0x80.
              if (radioChannelNotifySupported(
                context.read<MeshCoreConnector>(),
              ))
                Builder(
                  builder: (tileContext) {
                    final live = tileContext.watch<MeshCoreConnector>();
                    final effective = radioChannelNotifyEffective(
                      tileContext,
                      live.channelNotifyFor(channel),
                      live.deviceNotifyScope,
                    );
                    return ListTile(
                      leading: const Icon(Icons.volume_up_outlined),
                      title: Text(tileContext.l10n.channels_radioSound),
                      subtitle: Text(
                        effective ??
                            tileContext.l10n.channels_radioSoundReading,
                      ),
                      onTap: () async {
                        Navigator.pop(sheetContext);
                        await Future.delayed(const Duration(milliseconds: 100));
                        if (parentContext.mounted) {
                          showRadioChannelNotifyDialog(parentContext, channel);
                        }
                      },
                    );
                  },
                ),
              // The radio's own tone for this channel (#971), named apart from
              // Notifications, which is the phone's. Gated on caps byte 2 0x10.
              ChannelRadioToneTile(
                channel: channel,
                onTap: () async {
                  Navigator.pop(sheetContext);
                  await Future.delayed(const Duration(milliseconds: 100));
                  if (parentContext.mounted) {
                    showChannelRadioToneDialog(parentContext, channel);
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.red),
                title: Text(
                  context.l10n.channels_deleteChannel,
                  style: const TextStyle(color: Colors.red),
                ),
                onTap: () async {
                  Navigator.pop(sheetContext);
                  await Future.delayed(const Duration(milliseconds: 100));
                  if (parentContext.mounted) {
                    _confirmDeleteChannel(
                      context,
                      connector,
                      channelMessageStore,
                      channel,
                    );
                  }
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Shared open path for the channel tiles and the nav drawer list.
  Future<void> _openChannel(BuildContext context, Channel channel) async {
    final connector = context.read<MeshCoreConnector>();
    final unread = connector.getUnreadCountForChannelIndex(channel.index);
    connector.markChannelRead(channel.index);
    // The drawer closes itself in ChannelDrawerList, which has a context
    // inside it.
    await Future.delayed(const Duration(milliseconds: 50));
    if (!context.mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) =>
            ChannelChatScreen(channel: channel, initialUnreadCount: unread),
      ),
    );
  }

  void _handleQuickSwitch(int index, BuildContext context) {
    if (index == 1) return;
    switch (index) {
      case 0:
        Navigator.pushReplacement(
          context,
          buildQuickSwitchRoute(const ContactsScreen()),
        );
        break;
      case 2:
        Navigator.pushReplacement(
          context,
          buildQuickSwitchRoute(const MapScreen()),
        );
        break;
    }
  }

  Future<void> _disconnect(BuildContext context) async {
    final connector = context.read<MeshCoreConnector>();
    await showDisconnectDialog(context, connector);
  }

  Widget _buildFilterButton(UiViewStateService viewState) {
    return SortFilterMenu<ChannelSortOption>(
      tooltip: context.l10n.listFilter_tooltip,
      sections: [
        SortFilterMenuSection<ChannelSortOption>(
          title: context.l10n.channels_sortBy,
          options: [
            SortFilterMenuOption<ChannelSortOption>(
              value: ChannelSortOption.manual,
              label: context.l10n.channels_sortManual,
              checked: viewState.channelsSortOption == ChannelSortOption.manual,
            ),
            SortFilterMenuOption<ChannelSortOption>(
              value: ChannelSortOption.name,
              label: context.l10n.channels_sortAZ,
              checked: viewState.channelsSortOption == ChannelSortOption.name,
            ),
            SortFilterMenuOption<ChannelSortOption>(
              value: ChannelSortOption.latestMessages,
              label: context.l10n.channels_sortLatestMessages,
              checked:
                  viewState.channelsSortOption ==
                  ChannelSortOption.latestMessages,
            ),
            SortFilterMenuOption<ChannelSortOption>(
              value: ChannelSortOption.unread,
              label: context.l10n.channels_sortUnread,
              checked: viewState.channelsSortOption == ChannelSortOption.unread,
            ),
          ],
        ),
      ],
      onSelected: (sortOption) {
        viewState.setChannelsSortOption(sortOption);
      },
    );
  }

  List<Channel> _filterAndSortChannels(
    List<Channel> channels,
    MeshCoreConnector connector,
    UiViewStateService viewState,
  ) {
    var filtered = channels.where((channel) {
      if (viewState.channelsSearchText.isEmpty) return true;
      final label = _normalizeChannelName(channel);
      return label.toLowerCase().contains(
        viewState.channelsSearchText.toLowerCase(),
      );
    }).toList();

    int compareByName(Channel a, Channel b) {
      final nameA = _normalizeChannelName(a);
      final nameB = _normalizeChannelName(b);
      return nameA.toLowerCase().compareTo(nameB.toLowerCase());
    }

    switch (viewState.channelsSortOption) {
      case ChannelSortOption.manual:
        break;
      case ChannelSortOption.latestMessages:
        filtered.sort((a, b) {
          final aMessages = connector.getChannelMessages(a);
          final bMessages = connector.getChannelMessages(b);
          final aLast = aMessages.isEmpty
              ? DateTime(1970)
              : aMessages.last.timestamp;
          final bLast = bMessages.isEmpty
              ? DateTime(1970)
              : bMessages.last.timestamp;
          final timeCompare = bLast.compareTo(aLast);
          if (timeCompare != 0) return timeCompare;
          return compareByName(a, b);
        });
        break;
      case ChannelSortOption.unread:
        filtered.sort((a, b) {
          final aUnread = connector.getUnreadCountForChannel(a);
          final bUnread = connector.getUnreadCountForChannel(b);
          final unreadCompare = bUnread.compareTo(aUnread);
          if (unreadCompare != 0) return unreadCompare;
          return compareByName(a, b);
        });
        break;
      case ChannelSortOption.name:
        filtered.sort(compareByName);
        break;
    }

    return filtered;
  }

  String _normalizeChannelName(Channel channel) {
    if (channel.name.isEmpty) {
      return 'Channel ${channel.index}'; // Fallback for sorting
    }
    final trimmed = channel.name.trim();
    if (trimmed.startsWith('#') && trimmed.length > 1) {
      return trimmed.substring(1);
    }
    return trimmed;
  }

  void _showAddChannelDialog(BuildContext context) {
    final connector = context.read<MeshCoreConnector>();
    // No slot is chosen here. It used to be, and that was the bug: the channel
    // list is emptied for the duration of a sync, so an index picked when this
    // dialog opened could point at an occupied slot by the time Add was
    // pressed. Each handler now calls _allocateChannelSlot at the write (#1021).
    final hasPublicChannel = connector.channels.any((c) => c.isPublicChannel);
    int? selectedOption;
    final nameController = TextEditingController();
    final pskController = TextEditingController();
    final hashtagController = TextEditingController();
    bool addPublicChannel = true;
    bool isRegularHashtag = true;
    Community? selectedCommunity;

    _communityStore.setPublicKeyHex = connector.selfPublicKeyHex;

    showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          Widget buildOptionTile({
            required int optionIndex,
            required IconData icon,
            required String title,
            required String subtitle,
            bool enabled = true,
          }) {
            final isSelected = selectedOption == optionIndex;
            return ListTile(
              leading: CircleAvatar(
                backgroundColor: enabled
                    ? (isSelected
                          ? Theme.of(dialogContext).colorScheme.primaryContainer
                          : null)
                    : Colors.grey.withValues(alpha: 0.2),
                child: Icon(
                  icon,
                  color: enabled
                      ? (isSelected
                            ? Theme.of(dialogContext).colorScheme.primary
                            : null)
                      : Colors.grey,
                ),
              ),
              title: Text(
                title,
                style: TextStyle(color: enabled ? null : Colors.grey),
              ),
              subtitle: Text(
                subtitle,
                style: TextStyle(color: enabled ? null : Colors.grey),
              ),
              trailing: enabled ? const Icon(Icons.chevron_right) : null,
              selected: isSelected,
              onTap: enabled
                  ? () {
                      setDialogState(() {
                        selectedOption = optionIndex;
                        nameController.clear();
                        pskController.clear();
                        hashtagController.clear();
                      });
                    }
                  : null,
            );
          }

          Widget? buildExpandedContent(
            ChannelMessageStore channelMessageStore,
          ) {
            switch (selectedOption) {
              case 0: // Create Private Channel
                return Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: TextField(
                        controller: nameController,
                        decoration: InputDecoration(
                          labelText: dialogContext.l10n.channels_channelName,
                          border: const OutlineInputBorder(),
                        ),
                        maxLength: 31,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          Expanded(
                            child: FilledButton(
                              onPressed: () async {
                                final name = nameController.text.trim();
                                if (name.isEmpty) {
                                  showDismissibleSnackBar(
                                    context,
                                    content: Text(
                                      dialogContext
                                          .l10n
                                          .channels_enterChannelName,
                                    ),
                                  );
                                  return;
                                }
                                final random = Random.secure();
                                final psk = Uint8List(16);
                                for (int i = 0; i < 16; i++) {
                                  psk[i] = random.nextInt(256);
                                }
                                final slot = _allocateChannelSlot(
                                  dialogContext,
                                  connector,
                                  psk,
                                );
                                // Refused: leave the dialog open so the user
                                // can retry once the sync finishes.
                                if (slot == null) return;
                                Navigator.pop(dialogContext);
                                final result = await connector.setChannel(
                                  slot,
                                  name,
                                  psk,
                                );
                                // Only on OK: a refused write leaves another
                                // channel in this slot, and this would wipe
                                // that channel's history (#1026).
                                if (result == ChannelWrite.ok) {
                                  await channelMessageStore
                                      .clearChannelMessages(slot);
                                }
                                if (!context.mounted) return;
                                if (explainUnconfirmedChannelWrite(
                                  context,
                                  result,
                                )) {
                                  return;
                                }
                                showDismissibleSnackBar(
                                  context,
                                  content: Text(
                                    context.l10n.channels_channelAdded(name),
                                  ),
                                );
                              },
                              child: Text(dialogContext.l10n.common_create),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                );

              case 1: // Join Private Channel
                return Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: TextField(
                        controller: nameController,
                        decoration: InputDecoration(
                          labelText: dialogContext.l10n.channels_channelName,
                          border: const OutlineInputBorder(),
                        ),
                        maxLength: 31,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: TextField(
                        controller: pskController,
                        decoration: InputDecoration(
                          labelText: dialogContext.l10n.channels_pskHex,
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          Expanded(
                            child: FilledButton(
                              onPressed: () async {
                                final name = nameController.text.trim();
                                final pskHex = pskController.text.trim();
                                if (name.isEmpty) {
                                  showDismissibleSnackBar(
                                    context,
                                    content: Text(
                                      dialogContext
                                          .l10n
                                          .channels_enterChannelName,
                                    ),
                                  );
                                  return;
                                }
                                Uint8List psk;
                                try {
                                  psk = Channel.parsePskHex(pskHex);
                                } on FormatException {
                                  showDismissibleSnackBar(
                                    context,
                                    content: Text(
                                      dialogContext
                                          .l10n
                                          .channels_pskMustBe32Hex,
                                    ),
                                  );
                                  return;
                                }
                                final slot = _allocateChannelSlot(
                                  dialogContext,
                                  connector,
                                  psk,
                                );
                                if (slot == null) return;
                                Navigator.pop(dialogContext);
                                final result = await connector.setChannel(
                                  slot,
                                  name,
                                  psk,
                                );
                                if (!context.mounted) return;
                                if (explainUnconfirmedChannelWrite(
                                  context,
                                  result,
                                )) {
                                  return;
                                }
                                showDismissibleSnackBar(
                                  context,
                                  content: Text(
                                    context.l10n.channels_channelAdded(name),
                                  ),
                                );
                              },
                              child: Text(dialogContext.l10n.common_add),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                );

              case 2: // Join Public Channel
                return Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: FilledButton(
                          onPressed: () async {
                            final psk = Channel.parsePskHex(
                              Channel.publicChannelPsk,
                            );
                            final slot = _allocateChannelSlot(
                              dialogContext,
                              connector,
                              psk,
                            );
                            if (slot == null) return;
                            Navigator.pop(dialogContext);
                            final result = await connector.setChannel(
                              slot,
                              'Public',
                              psk,
                            );
                            if (!context.mounted) return;
                            if (explainUnconfirmedChannelWrite(
                              context,
                              result,
                            )) {
                              return;
                            }
                            showDismissibleSnackBar(
                              context,
                              content: Text(
                                context.l10n.channels_publicChannelAdded,
                              ),
                            );
                          },
                          child: Text(dialogContext.l10n.common_add),
                        ),
                      ),
                    ],
                  ),
                );

              case 3: // Join Hashtag Channel
                return Column(
                  children: [
                    // Only show type selection if user has communities
                    if (_communities.isNotEmpty) ...[
                      RadioGroup<bool>(
                        groupValue: isRegularHashtag,
                        onChanged: (v) => setDialogState(() {
                          if (v == null) return;
                          isRegularHashtag = v;
                          if (isRegularHashtag) {
                            selectedCommunity = null;
                          } else if (selectedCommunity == null &&
                              _communities.isNotEmpty) {
                            selectedCommunity = _communities.first;
                          }
                        }),
                        child: Column(
                          children: [
                            RadioListTile<bool>(
                              value: true,
                              title: Text(
                                dialogContext.l10n.community_regularHashtag,
                              ),
                              subtitle: Text(
                                dialogContext.l10n.community_regularHashtagDesc,
                              ),
                              dense: true,
                            ),
                            RadioListTile<bool>(
                              value: false,
                              title: Text(
                                dialogContext.l10n.community_communityHashtag,
                              ),
                              subtitle: Text(
                                dialogContext
                                    .l10n
                                    .community_communityHashtagDesc,
                              ),
                              dense: true,
                            ),
                          ],
                        ),
                      ),
                    ],
                    // Community dropdown (only if community hashtag selected)
                    if (!isRegularHashtag && _communities.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        child: DropdownButtonFormField<Community>(
                          initialValue: selectedCommunity,
                          items: _communities
                              .map(
                                (c) => DropdownMenuItem(
                                  value: c,
                                  child: Text(c.name),
                                ),
                              )
                              .toList(),
                          onChanged: (c) =>
                              setDialogState(() => selectedCommunity = c),
                          decoration: InputDecoration(
                            labelText:
                                dialogContext.l10n.community_selectCommunity,
                            border: const OutlineInputBorder(),
                            prefixIcon: const Icon(Icons.groups),
                          ),
                        ),
                      ),
                    // Hashtag name input
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: TextField(
                        controller: hashtagController,
                        decoration: InputDecoration(
                          labelText: dialogContext.l10n.channels_enterHashtag,
                          hintText: dialogContext.l10n.channels_hashtagHint,
                          border: const OutlineInputBorder(),
                          prefixIcon: const Icon(Icons.tag),
                        ),
                        maxLength: 31,
                      ),
                    ),
                    // Privacy hint for community hashtags
                    if (!isRegularHashtag)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Text(
                          dialogContext.l10n.community_hashtagPrivacyHint,
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[600],
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: FilledButton(
                              onPressed: () async {
                                var hashtag = hashtagController.text.trim();
                                if (hashtag.isEmpty) {
                                  showDismissibleSnackBar(
                                    context,
                                    content: Text(
                                      dialogContext
                                          .l10n
                                          .channels_enterChannelName,
                                    ),
                                  );
                                  return;
                                }

                                // Normalize hashtag name (remove leading # if present)
                                if (hashtag.startsWith('#')) {
                                  hashtag = hashtag.substring(1);
                                }
                                final String channelName;

                                final Uint8List psk;
                                if (isRegularHashtag &&
                                    Channel.hashtagMeansPublic(hashtag)) {
                                  // "public" means the real Public, as on the
                                  // device (#1896), not sha256("#public").
                                  channelName = 'Public';
                                  psk = Channel.parsePskHex(
                                    Channel.publicChannelPsk,
                                  );
                                } else if (isRegularHashtag) {
                                  channelName = '#$hashtag';
                                  // Regular hashtag - public derivation using SHA256
                                  psk = Channel.derivePskFromHashtag(hashtag);
                                } else {
                                  // Community hashtag - HMAC derivation from community secret
                                  if (selectedCommunity == null) {
                                    showDismissibleSnackBar(
                                      dialogContext,
                                      content: Text(
                                        dialogContext
                                            .l10n
                                            .community_selectCommunity,
                                      ),
                                    );
                                    return;
                                  }
                                  channelName =
                                      '${selectedCommunity!.name} #$hashtag';
                                  psk = selectedCommunity!
                                      .deriveCommunityHashtagPsk(hashtag);
                                  // Track in community's hashtag list
                                  await _communityStore.addHashtagChannel(
                                    selectedCommunity!.id,
                                    hashtag,
                                  );
                                  _loadCommunities();
                                }

                                // The screen's context, not the dialog's: the
                                // hashtag store write above is awaited, so the
                                // dialog may already be gone by here.
                                if (!context.mounted) return;
                                final slot = _allocateChannelSlot(
                                  context,
                                  connector,
                                  psk,
                                );
                                if (slot == null) return;
                                if (dialogContext.mounted) {
                                  Navigator.pop(dialogContext);
                                }
                                final result = await connector.setChannel(
                                  slot,
                                  channelName,
                                  psk,
                                );
                                if (!context.mounted) return;
                                if (explainUnconfirmedChannelWrite(
                                  context,
                                  result,
                                )) {
                                  return;
                                }
                                showDismissibleSnackBar(
                                  context,
                                  content: Text(
                                    context.l10n.channels_channelAdded(
                                      channelName,
                                    ),
                                  ),
                                );
                              },
                              child: Text(dialogContext.l10n.common_add),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                );

              case 4: // Scan Community QR
                return Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: () async {
                            Navigator.pop(dialogContext);
                            if (context.mounted) {
                              final result = await Navigator.push<Community>(
                                context,
                                MaterialPageRoute(
                                  builder: (context) =>
                                      const CommunityQrScannerScreen(),
                                ),
                              );
                              // Result handled by scanner screen
                              if (result != null && context.mounted) {
                                // Community was joined, refresh might be needed
                              }
                            }
                          },
                          icon: const Icon(Icons.qr_code_scanner),
                          label: Text(dialogContext.l10n.community_scanQr),
                        ),
                      ),
                    ],
                  ),
                );

              case 5: // Create Community
                return Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: TextField(
                        controller: nameController,
                        decoration: InputDecoration(
                          labelText: dialogContext.l10n.community_name,
                          hintText: dialogContext.l10n.community_enterName,
                          border: const OutlineInputBorder(),
                          prefixIcon: const Icon(Icons.groups),
                        ),
                        maxLength: 31,
                      ),
                    ),
                    CheckboxListTile(
                      value: addPublicChannel,
                      onChanged: (value) {
                        setDialogState(() {
                          addPublicChannel = value ?? true;
                        });
                      },
                      title: Text(
                        dialogContext.l10n.community_addPublicChannel,
                      ),
                      subtitle: Text(
                        dialogContext.l10n.community_addPublicChannelHint,
                      ),
                      controlAffinity: ListTileControlAffinity.leading,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          Expanded(
                            child: FilledButton(
                              onPressed: () async {
                                final name = nameController.text.trim();
                                if (name.isEmpty) {
                                  showDismissibleSnackBar(
                                    context,
                                    content: Text(
                                      dialogContext.l10n.community_enterName,
                                    ),
                                  );
                                  return;
                                }

                                // Create community with random secret
                                final community = Community.create(
                                  id: const Uuid().v4(),
                                  name: name,
                                );

                                // Save to store
                                await _communityStore.addCommunity(community);

                                // Optionally add the community public channel to the device.
                                // The community itself is already saved above,
                                // so a refused slot skips only the channel
                                // write and never loses the community. Uses the
                                // screen's context, not the dialog's: this runs
                                // after an await and the dialog may be gone.
                                int? slot;
                                var channelRefused = false;
                                if (addPublicChannel && context.mounted) {
                                  slot = _allocateChannelSlot(
                                    context,
                                    connector,
                                    community.deriveCommunityPublicPsk(),
                                  );
                                  channelRefused = slot == null;
                                }

                                // Closed before the write, which now waits for
                                // the radio: an open dialog would let a second
                                // tap create the community twice.
                                if (dialogContext.mounted) {
                                  Navigator.pop(dialogContext);
                                }

                                // Refresh communities list
                                _loadCommunities();

                                if (slot != null) {
                                  final result = await connector.setChannel(
                                    slot,
                                    '${community.name} Public',
                                    community.deriveCommunityPublicPsk(),
                                  );
                                  if (context.mounted) {
                                    channelRefused =
                                        explainUnconfirmedChannelWrite(
                                          context,
                                          result,
                                        );
                                  }
                                }

                                if (context.mounted) {
                                  // A refusal's message is showing and
                                  // persists; this toast would replace it
                                  // (#1026). The QR below still shows: the
                                  // community was created either way.
                                  if (!channelRefused) {
                                    showDismissibleSnackBar(
                                      context,
                                      content: Text(
                                        context.l10n.community_created(name),
                                      ),
                                    );
                                  }

                                  // Show QR code dialog
                                  await QrCodeShareDialog.show(
                                    context: context,
                                    data: community.toQrJson(),
                                    title: context.l10n.community_qrTitle,
                                    instructions: context.l10n
                                        .community_qrInstructions(name),
                                    embeddedImage: Image.asset(
                                      'assets/images/mesh-icon.png',
                                      width: 40,
                                      height: 40,
                                    ),
                                  );
                                }
                              },
                              child: Text(dialogContext.l10n.common_create),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                );

              default:
                return null;
            }
          }

          return AlertDialog(
            title: Text(dialogContext.l10n.channels_addChannel),
            contentPadding: const EdgeInsets.symmetric(vertical: 16),
            content: SizedBox(
              width: double.maxFinite,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    buildOptionTile(
                      optionIndex: 0,
                      icon: Icons.add,
                      title: dialogContext.l10n.channels_createPrivateChannel,
                      subtitle:
                          dialogContext.l10n.channels_createPrivateChannelDesc,
                    ),
                    if (selectedOption == 0)
                      buildExpandedContent(_channelMessageStore)!,
                    const Divider(height: 1),
                    buildOptionTile(
                      optionIndex: 1,
                      icon: Icons.lock,
                      title: dialogContext.l10n.channels_joinPrivateChannel,
                      subtitle:
                          dialogContext.l10n.channels_joinPrivateChannelDesc,
                    ),
                    if (selectedOption == 1)
                      buildExpandedContent(_channelMessageStore)!,
                    if (!hasPublicChannel) ...[
                      const Divider(height: 1),
                      buildOptionTile(
                        optionIndex: 2,
                        icon: Icons.public,
                        title: dialogContext.l10n.channels_joinPublicChannel,
                        subtitle:
                            dialogContext.l10n.channels_joinPublicChannelDesc,
                      ),
                      if (selectedOption == 2)
                        buildExpandedContent(_channelMessageStore)!,
                    ],
                    const Divider(height: 1),
                    buildOptionTile(
                      optionIndex: 3,
                      icon: Icons.tag,
                      title: dialogContext.l10n.channels_joinHashtagChannel,
                      subtitle:
                          dialogContext.l10n.channels_joinHashtagChannelDesc,
                    ),
                    if (selectedOption == 3)
                      buildExpandedContent(_channelMessageStore)!,
                    const Divider(height: 1),
                    buildOptionTile(
                      optionIndex: 4,
                      icon: Icons.qr_code_scanner,
                      title: dialogContext.l10n.channels_scanQr,
                      subtitle: dialogContext.l10n.channels_scanQrDesc,
                    ),
                    if (selectedOption == 4)
                      buildExpandedContent(_channelMessageStore)!,
                    const Divider(height: 1),
                    buildOptionTile(
                      optionIndex: 5,
                      icon: Icons.groups,
                      title: dialogContext.l10n.community_create,
                      subtitle: dialogContext.l10n.community_createDesc,
                    ),
                    if (selectedOption == 5)
                      buildExpandedContent(_channelMessageStore)!,
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: Text(dialogContext.l10n.common_close),
              ),
            ],
          );
        },
      ),
    );
  }

  void _showEditChannelDialog(
    BuildContext context,
    MeshCoreConnector connector,
    Channel channel,
  ) {
    final appSettingsService = Provider.of<AppSettingsService>(
      context,
      listen: false,
    );
    final channelType = Channel.getChannelType(channel, _communityIndex);
    final pskLocked = !channelPskEditable(channelType);
    final nameLocked = !channelNameEditable(channelType);
    final nameController = TextEditingController(text: channel.name);
    final pskController = TextEditingController(text: channel.pskHex);
    bool cyr2latEnabled = connector.isChannelCyr2LatEnabled(channel.index);
    String? selectedCyr2LatProfileId = connector.getChannelCyr2LatProfileId(
      channel.index,
    );
    String? nameError;

    showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setState) => AlertDialog(
          title: Text(
            dialogContext.l10n.channels_editChannelTitle(channel.index),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  readOnly: nameLocked,
                  decoration: InputDecoration(
                    labelText: dialogContext.l10n.channels_channelName,
                    border: const OutlineInputBorder(),
                    helperText: nameLocked
                        ? dialogContext.l10n.channels_communityDerived
                        : null,
                    helperMaxLines: 2,
                    errorText: nameError,
                    errorMaxLines: 2,
                  ),
                  maxLength: 31,
                  // #1103: a hashtag channel's key IS its name, so a rename
                  // re-derives it live, exactly as adding that hashtag would.
                  onChanged: channelType == ChannelType.hashtag
                      ? (value) => setState(() {
                          nameError = null;
                          final trimmed = value.trim();
                          if (editedNameKeepsType(channelType, trimmed)) {
                            pskController.text = Channel.formatPskHex(
                              Channel.derivePskFromHashtag(trimmed),
                            );
                          }
                        })
                      : null,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: pskController,
                  readOnly: pskLocked,
                  decoration: InputDecoration(
                    labelText: dialogContext.l10n.channels_pskHex,
                    border: const OutlineInputBorder(),
                    helperText: pskLocked
                        ? (channelType == ChannelType.hashtag
                              ? dialogContext.l10n.channels_pskDerivedFromName
                              : dialogContext.l10n.channels_communityDerived)
                        : null,
                    helperMaxLines: 2,
                    // #1103: a derived key is never hand-edited or rolled,
                    // but it stays copyable (OpenHop routing rules need it).
                    suffixIcon: pskLocked
                        ? IconButton(
                            icon: const Icon(Icons.copy),
                            tooltip: dialogContext.l10n.channels_copyPsk,
                            onPressed: () {
                              Clipboard.setData(
                                ClipboardData(text: pskController.text),
                              );
                              showDismissibleSnackBar(
                                dialogContext,
                                content: Text(
                                  dialogContext.l10n.channels_pskCopied,
                                ),
                              );
                            },
                          )
                        : IconButton(
                            icon: const Icon(Icons.casino),
                            tooltip:
                                dialogContext.l10n.channels_generateRandomPsk,
                            onPressed: () {
                              final random = Random.secure();
                              final bytes = Uint8List(16);
                              for (int i = 0; i < 16; i++) {
                                bytes[i] = random.nextInt(256);
                              }
                              pskController.text = Channel.formatPskHex(bytes);
                            },
                          ),
                  ),
                ),
                const SizedBox(height: 16),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(dialogContext.l10n.channels_cyr2latCompression),
                  subtitle: Text(
                    dialogContext.l10n.channels_cyr2latCompressionDscr,
                  ),
                  value: cyr2latEnabled,
                  onChanged: (value) => setState(() {
                    cyr2latEnabled = value;
                  }),
                ),
                if (cyr2latEnabled) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(0, 8, 0, 8),
                    child: DropdownButtonFormField<String>(
                      initialValue: selectedCyr2LatProfileId,
                      decoration: InputDecoration(
                        labelText: dialogContext
                            .l10n
                            .channels_cyr2latSettingsSubheading,
                        border: const OutlineInputBorder(),
                      ),
                      items: appSettingsService.settings.cyr2latProfiles.map((
                        profile,
                      ) {
                        return DropdownMenuItem(
                          value: profile.id,
                          child: Text(profile.name),
                        );
                      }).toList(),
                      onChanged: (value) => setState(() {
                        selectedCyr2LatProfileId = value;
                      }),
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(dialogContext.l10n.common_cancel),
            ),
            FilledButton(
              onPressed: () async {
                final name = nameLocked
                    ? channel.name
                    : nameController.text.trim();
                // #1103: a hashtag channel stays a hashtag; its key derives
                // from the '#' name. A different kind of channel is an add,
                // not an edit. Refuse the write and say why, inline.
                if (!editedNameKeepsType(channelType, name)) {
                  setState(() {
                    nameError = dialogContext.l10n.channels_hashtagMustKeepHash;
                  });
                  return;
                }

                // Checked first: mid-sync the list is empty, so the identity
                // check below would close the dialog and blame a changed
                // channel. This keeps the dialog, and the user's edits, open
                // and gives the real reason (#1021, #1026).
                if (refuseWhileChannelTableBusy(dialogContext, connector)) {
                  return;
                }
                // #1103 review: this dialog captured the channel when it
                // opened. If a sync replaced the slot's identity meanwhile
                // (the #1060 class), writing by the captured index would hit
                // the NEW occupant with the OLD dialog's rules. Refuse the
                // write and say why.
                final live = connector.channels.cast<Channel?>().firstWhere(
                  (c) => c?.index == channel.index,
                  orElse: () => null,
                );
                if (live == null || live.pskHex != channel.pskHex) {
                  Navigator.pop(dialogContext);
                  showDismissibleSnackBar(
                    context,
                    content: Text(context.l10n.channels_channelChangedReopen),
                    backgroundColor: Theme.of(context).colorScheme.error,
                    persist: true,
                  );
                  return;
                }

                final Uint8List psk;
                if (channelType == ChannelType.hashtag) {
                  // The key IS the (possibly renamed) name, never the field.
                  psk = Channel.derivePskFromHashtag(name);
                } else if (pskLocked) {
                  psk = channel.psk;
                } else {
                  try {
                    psk = Channel.parsePskHex(pskController.text.trim());
                  } on FormatException {
                    showDismissibleSnackBar(
                      dialogContext,
                      content: Text(dialogContext.l10n.channels_pskMustBe32Hex),
                    );
                    return;
                  }
                }
                // Typing Public's key into another channel would make a
                // second Public, which the radio refuses (#1896). Say so here
                // instead of reporting a generic refusal.
                if (Channel.isPublicKey(psk) &&
                    !channel.isPublicChannel &&
                    refusePublicAlreadyOnRadio(dialogContext, connector)) {
                  return;
                }

                Navigator.pop(dialogContext);
                try {
                  final result = await connector.editChannel(
                    channel,
                    name,
                    psk,
                  );
                  if (result != ChannelWrite.ok) {
                    if (!context.mounted) return;
                    explainUnconfirmedChannelWrite(context, result);
                    return;
                  }
                  await connector.setChannelCyr2LatEnabled(
                    channel.index,
                    cyr2latEnabled,
                  );
                  await connector.setChannelCyr2LatProfileId(
                    channel.index,
                    selectedCyr2LatProfileId,
                  );
                  if (!context.mounted) return;
                  showDismissibleSnackBar(
                    context,
                    content: Text(context.l10n.channels_channelUpdated(name)),
                  );
                } catch (e, st) {
                  debugPrint(st.toString());
                  if (!context.mounted) return;
                  showDismissibleSnackBar(
                    context,
                    content: Text(
                      context.l10n.channels_channelUpdateFailed('$e'),
                    ),
                  );
                }
              },
              child: Text(dialogContext.l10n.common_save),
            ),
          ],
        ),
      ),
    ).whenComplete(() {
      nameController.dispose();
      pskController.dispose();
    });
  }

  /// Writes the client's cached channels back onto a radio that lost them
  /// (#1060). Confirmed first: it overwrites whatever those slots hold now.
  Future<void> _confirmRestoreChannels(
    BuildContext context,
    MeshCoreConnector connector,
  ) async {
    final toRestore = connector.cachedChannels
        .where((c) => !c.isUnusable)
        .toList();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(dialogContext.l10n.channels_restoreToRadio),
        content: Text(
          dialogContext.l10n.channels_restoreToRadioConfirm(
            toRestore.length,
            toRestore.map((c) => c.name).join(', '),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(dialogContext.l10n.common_cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(dialogContext.l10n.channels_restoreToRadio),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    // Its writes share the reply queue with any sync or other channel write,
    // so like every channel write it waits for a quiet table (#1026).
    if (!context.mounted) return;
    if (refuseWhileChannelTableBusy(context, connector)) return;

    final written = await connector.restoreChannelsToRadio();
    if (!context.mounted) return;
    showDismissibleSnackBar(
      context,
      content: Text(
        written < 0
            ? context.l10n.channels_restoreToRadioFailed
            : context.l10n.channels_restoreToRadioDone(written),
      ),
      persist: written < 0,
    );
  }

  void _confirmDeleteChannel(
    BuildContext context,
    MeshCoreConnector connector,
    ChannelMessageStore channelMessageStore,
    Channel channel,
  ) {
    if (refuseDeletingPublic(context, channel)) return;
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(dialogContext.l10n.channels_deleteChannel),
        content: Text(
          dialogContext.l10n.channels_deleteChannelConfirm(channel.name),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(dialogContext.l10n.common_cancel),
          ),
          TextButton(
            onPressed: () async {
              if (refuseWhileChannelTableBusy(dialogContext, connector)) {
                return;
              }
              Navigator.pop(dialogContext);
              try {
                final result = await connector.deleteChannel(channel.index);

                // Only on OK: if the radio kept the channel, it keeps its
                // history too (#1026).
                if (result == ChannelWrite.ok) {
                  await channelMessageStore.clearChannelMessages(channel.index);
                }

                if (!context.mounted) return;
                if (explainUnconfirmedChannelWrite(context, result)) return;

                showDismissibleSnackBar(
                  context,
                  content: Text(
                    context.l10n.channels_channelDeleted(channel.name),
                  ),
                );
              } catch (e, st) {
                if (!context.mounted) return;

                showDismissibleSnackBar(
                  context,
                  content: Text(
                    context.l10n.channels_channelDeleteFailed(channel.name),
                  ),
                );

                // Preserve existing logging (if it was there)
                debugPrint('Failed to delete channel: $e\n$st');
              }
            },
            child: Text(
              dialogContext.l10n.common_delete,
              style: const TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _addPublicChannel(
    BuildContext context,
    MeshCoreConnector connector,
  ) async {
    // This used to write slot 0 unconditionally, with no occupancy check, so
    // it overwrote whatever was there (#1021). It now goes through the shared
    // allocator, which refuses a second Public and puts Public in slot 0, the
    // slot firmware reserves for it (#1896), whenever slot 0 is free.
    final psk = Channel.parsePskHex(Channel.publicChannelPsk);
    final slot = _allocateChannelSlot(context, connector, psk);
    if (slot == null) return;
    final result = await connector.setChannel(slot, 'Public', psk);
    if (!context.mounted) return;
    if (explainUnconfirmedChannelWrite(context, result)) return;
    showDismissibleSnackBar(
      context,
      content: Text(context.l10n.channels_publicChannelAdded),
    );
  }

  /// Thin alias for the shared allocator, kept so the five call sites in this
  /// file read the same as before. The logic lives in
  /// `helpers/channel_slot_ui.dart` so this screen, the QR scanner and config
  /// import all answer "which slot is free?" the same way (#1021).
  int? _allocateChannelSlot(
    BuildContext context,
    MeshCoreConnector connector,
    Uint8List psk,
  ) => allocateChannelSlotOrExplain(context, connector, psk: psk);

  void _showManageCommunitiesDialog(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => DraggableScrollableSheet(
        initialChildSize: 0.5,
        minChildSize: 0.3,
        maxChildSize: 0.9,
        expand: false,
        builder: (_, scrollController) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const Icon(Icons.groups, size: 28),
                  const SizedBox(width: 12),
                  Text(
                    context.l10n.community_manageCommunities,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _communities.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.groups_outlined,
                            size: 64,
                            color: Colors.grey[400],
                          ),
                          const SizedBox(height: 16),
                          Text(
                            context.l10n.community_noCommunities,
                            style: TextStyle(
                              fontSize: 16,
                              color: Colors.grey[600],
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            context.l10n.community_scanOrCreate,
                            style: TextStyle(
                              fontSize: 14,
                              color: Colors.grey[500],
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      controller: scrollController,
                      itemCount: _communities.length,
                      itemBuilder: (context, index) {
                        final community = _communities[index];
                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor: Colors.purple.withValues(
                              alpha: 0.2,
                            ),
                            child: const Icon(
                              Icons.groups,
                              color: Colors.purple,
                            ),
                          ),
                          title: Text(community.name),
                          subtitle: Text(
                            'ID: ${community.shortCommunityId}...',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey[600],
                            ),
                          ),
                          trailing: PopupMenuButton<String>(
                            onSelected: (value) {
                              Navigator.pop(sheetContext);
                              if (value == 'share') {
                                _showCommunityQrDialog(context, community);
                              } else if (value == 'leave') {
                                _confirmLeaveCommunity(context, community);
                              }
                            },
                            itemBuilder: (context) => [
                              PopupMenuItem(
                                value: 'share',
                                child: Row(
                                  children: [
                                    const Icon(Icons.qr_code),
                                    const SizedBox(width: 12),
                                    Text(context.l10n.community_showQr),
                                  ],
                                ),
                              ),
                              PopupMenuItem(
                                value: 'leave',
                                child: Row(
                                  children: [
                                    const Icon(
                                      Icons.exit_to_app,
                                      color: Colors.red,
                                    ),
                                    const SizedBox(width: 12),
                                    Text(
                                      context.l10n.community_delete,
                                      style: const TextStyle(color: Colors.red),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          onTap: () {
                            Navigator.pop(sheetContext);
                            _showCommunityQrDialog(context, community);
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

  void _showCommunityQrDialog(BuildContext context, Community community) {
    QrCodeShareDialog.show(
      context: context,
      data: community.toQrJson(),
      title: context.l10n.community_qrTitle,
      instructions: context.l10n.community_qrInstructions(community.name),
      embeddedImage: Image.asset(
        'assets/images/mesh-icon.png',
        width: 40,
        height: 40,
      ),
    );
  }

  void _showChannelQrDialog(BuildContext context, Channel channel) {
    QrCodeShareDialog.show(
      context: context,
      data: channel.toShareUri(),
      title: context.l10n.channels_shareQrTitle,
      instructions: context.l10n.channels_shareQrInstructions(channel.name),
      embeddedImage: Image.asset(
        'assets/images/mesh-icon.png',
        width: 40,
        height: 40,
      ),
    );
  }

  void _confirmLeaveCommunity(BuildContext context, Community community) {
    final connector = context.read<MeshCoreConnector>();

    // Find all channels that belong to this community
    List<Channel> communityChannels = [];
    final publicPskHex = Channel.formatPskHex(
      community.deriveCommunityPublicPsk(),
    );

    for (final channel in connector.channels) {
      // Check if it's the public channel
      if (channel.pskHex == publicPskHex) {
        communityChannels.add(channel);
        continue;
      }
      // Check if it's a hashtag channel
      for (final hashtag in community.hashtagChannels) {
        final hashtagPskHex = Channel.formatPskHex(
          community.deriveCommunityHashtagPsk(hashtag),
        );
        if (channel.pskHex == hashtagPskHex) {
          communityChannels.add(channel);
          break;
        }
      }
    }

    final channelCount = communityChannels.length;
    _communityStore.setPublicKeyHex = connector.selfPublicKeyHex;

    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(dialogContext.l10n.community_delete),
        content: Text(
          channelCount > 0
              ? '${dialogContext.l10n.community_deleteConfirm(community.name)}\n\n${dialogContext.l10n.community_deleteChannelsWarning(channelCount)}'
              : dialogContext.l10n.community_deleteConfirm(community.name),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(dialogContext.l10n.common_cancel),
          ),
          TextButton(
            onPressed: () async {
              if (communityChannels.isNotEmpty &&
                  refuseWhileChannelTableBusy(dialogContext, connector)) {
                return;
              }
              Navigator.pop(dialogContext);

              // Delete all community channels from the device. Each delete is
              // answered before the next goes out, and the list is re-read
              // once at the end. A sync between two deletes would share their
              // reply queue, so the loop runs as one batch (#1026).
              final failure = await connector.batchChannelWrites(() async {
                ChannelWrite? first;
                for (final channel in communityChannels) {
                  final result = await connector.deleteChannel(
                    channel.index,
                    refresh: false,
                  );
                  if (result != ChannelWrite.ok) first ??= result;
                }
                return first;
              });
              if (communityChannels.isNotEmpty) {
                await connector.getChannels(force: true);
              }

              // Remove community from store
              await _communityStore.removeCommunity(community.id);
              _loadCommunities();

              if (!context.mounted) return;
              if (failure != null &&
                  explainUnconfirmedChannelWrite(context, failure)) {
                return;
              }
              showDismissibleSnackBar(
                context,
                content: Text(context.l10n.community_deleted(community.name)),
              );
            },
            child: Text(
              dialogContext.l10n.community_delete,
              style: const TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );
  }
}

/// #1103: what the Edit Channel dialog may change, by channel type.
///
/// A hashtag channel's key IS its name (Channel.derivePskFromHashtag), so the
/// key is never hand-editable and a rename re-derives it. A community
/// hashtag's name and key both derive from the community secret, so both are
/// locked and managed through the community. Public's key is fixed: a new key
/// would make it a different channel, and firmware #1896 refuses the clear
/// that a key change needs. The key stays visible and copyable in every case:
/// OpenHop routing rules need it.
bool channelPskEditable(ChannelType type) =>
    type != ChannelType.hashtag &&
    type != ChannelType.communityHashtag &&
    type != ChannelType.public;

bool channelNameEditable(ChannelType type) =>
    type != ChannelType.communityHashtag;

/// A hashtag channel must stay a hashtag: its key derives from the '#' name.
/// Exactly ONE leading '#': a '##name' would hash differently from the
/// '#name' everyone else derives, silently isolating the user (review
/// finding). Converting to another kind of channel is an add, not an edit
/// (#1103).
bool editedNameKeepsType(ChannelType type, String newName) =>
    type != ChannelType.hashtag ||
    (newName.startsWith('#') &&
        !newName.startsWith('##') &&
        newName.length > 1);
