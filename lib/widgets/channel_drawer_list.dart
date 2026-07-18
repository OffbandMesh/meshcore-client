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
      onTap: onTap,
    );
  }
}
