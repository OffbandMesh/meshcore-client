import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../l10n/l10n.dart';
import '../models/channel.dart';
import 'unread_badge.dart';

/// Channel list rendered inside the nav drawer.
///
/// Lets you see every channel's unread count and jump straight to another
/// channel without backing out of the one you are reading.
///
/// [currentChannelIndex] highlights the channel you are in, and is null on the
/// channels list screen where no channel is open.
class ChannelDrawerList extends StatelessWidget {
  final int? currentChannelIndex;
  final ValueChanged<Channel> onChannelSelected;

  const ChannelDrawerList({
    super.key,
    required this.onChannelSelected,
    this.currentChannelIndex,
  });

  @override
  Widget build(BuildContext context) {
    // watch, deliberately. context.select cannot help here: `channels` is
    // `List.unmodifiable(_channels)`, a fresh instance per call, and Dart lists
    // have no value equality, so select would see a new object every
    // notification and rebuild just as often. Selecting on `length` instead
    // would go stale on a rename or reorder. The rebuild is cheap regardless:
    // ListView.builder only builds visible tiles, and each tile isolates its
    // own unread count with select.
    final channels = context.watch<MeshCoreConnector>().channels;

    if (channels.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            context.l10n.channels_title,
            style: Theme.of(context).textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return ListView.builder(
      padding: EdgeInsets.zero,
      itemCount: channels.length,
      itemBuilder: (context, i) {
        final channel = channels[i];
        return _ChannelDrawerTile(
          channel: channel,
          selected: channel.index == currentChannelIndex,
          onTap: () => onChannelSelected(channel),
        );
      },
    );
  }
}

class _ChannelDrawerTile extends StatelessWidget {
  final Channel channel;
  final bool selected;
  final VoidCallback onTap;

  const _ChannelDrawerTile({
    required this.channel,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // Selector keeps the rebuild to this tile when its unread count moves.
    final unread = context.select<MeshCoreConnector, int>(
      (c) => c.getUnreadCountForChannelIndex(channel.index),
    );
    final theme = Theme.of(context);

    return ListTile(
      dense: true,
      selected: selected,
      selectedTileColor: theme.colorScheme.secondaryContainer,
      leading: Icon(
        channel.isPublicChannel ? Icons.public : Icons.tag,
        size: 20,
      ),
      title: Text(
        channel.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontWeight: unread > 0 ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
      trailing: unread > 0 ? UnreadBadge(count: unread) : null,
      onTap: () {
        // Close from here, not from the caller: this context is inside the
        // Drawer, whereas a screen's State context sits above the Scaffold and
        // would never resolve it. Pinned layouts have no drawer to close.
        final scaffold = Scaffold.maybeOf(context);
        if (scaffold?.isDrawerOpen ?? false) {
          scaffold!.closeDrawer();
        }
        onTap();
      },
    );
  }
}
