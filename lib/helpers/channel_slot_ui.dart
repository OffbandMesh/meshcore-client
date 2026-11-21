import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../connector/meshcore_connector.dart';
import '../l10n/l10n.dart';
import '../models/channel.dart';
import 'channel_slot_decision.dart';
import 'snack_bar_builder.dart';

/// A channel slot that is safe to write right now, or null after telling the
/// user why not (#1021).
///
/// Every surface that adds a channel goes through this one function: the
/// channels screen, the community QR scanner, and anything else that writes a
/// slot. That is deliberate. The bug this fixes existed because the same
/// question ("which slot is free?") was answered three different ways in three
/// files, and only one of them was wrong. One answer cannot drift.
///
/// Call it at the moment of the write and never earlier. The connector empties
/// its channel list for the duration of a channel sync, and `setChannel` itself
/// starts one, so a slot chosen before a dialog or a confirmation can point at
/// an occupied slot by the time it is written.
///
/// The owner's ruling is that the unsafe write is blocked but the control stays
/// live: a greyed-out button prevents the damage and tells the user nothing. So
/// a refusal returns null *and* says what is wrong.
///
/// [psk] is the key about to be written. Public's key gets slot 0 and nothing
/// else does (#1896), and a second copy of Public is refused, whichever path
/// the key came in by: Join Public, a typed private key, a QR share, or a
/// hashtag join of "public".
int? allocateChannelSlotOrExplain(
  BuildContext context,
  MeshCoreConnector connector, {
  required Uint8List psk,
}) {
  final isPublic = Channel.isPublicKey(psk);
  if (isPublic && refusePublicAlreadyOnRadio(context, connector)) return null;
  final decision = decideChannelSlot(
    channels: connector.channels,
    maxChannels: connector.maxChannels,
    // Not hasLoadedChannels: that stays false after a FAILED sync while the
    // cached list is restored, so gating on it would make adding a channel
    // impossible on a flaky link. Busy also covers a write the radio has not
    // answered yet (#1026): until it does, the list does not show its slot.
    isSyncing: connector.isChannelTableBusy,
    isPublic: isPublic,
  );
  switch (decision.refusal) {
    case ChannelSlotRefusal.syncing:
      showChannelBlockedMessage(context, context.l10n.channels_slotBusySyncing);
      return null;
    case ChannelSlotRefusal.full:
      showChannelBlockedMessage(
        context,
        context.l10n.channels_slotsAllFull(connector.maxChannels),
      );
      return null;
    case null:
      return decision.slot;
  }
}

/// A refusal the user has to be able to read and act on, so it persists until
/// dismissed.
///
/// `showDismissibleSnackBar` defaults to `persist: false` and a 4 second toast,
/// which SAFELANE 6 rules out for an error.
void showChannelBlockedMessage(BuildContext context, String message) {
  showDismissibleSnackBar(context, content: Text(message), persist: true);
}

/// Explains a channel write the radio did not confirm, and returns true if it
/// did. A caller shows its own success message only when this returns false,
/// so nothing claims success before the radio has said OK (#1026).
///
/// A success toast shown after this would replace the explanation (a newer
/// toast replaces the visible one), so callers must not show one.
bool explainUnconfirmedChannelWrite(BuildContext context, ChannelWrite result) {
  final l10n = context.l10n;
  final message = switch (result) {
    ChannelWrite.ok => null,
    ChannelWrite.occupied => l10n.channels_writeOccupied,
    ChannelWrite.rejected => l10n.channels_writeRejected,
    ChannelWrite.noReply => l10n.channels_writeNoReply,
    ChannelWrite.clearedNotAdded => l10n.channels_writeClearedNotAdded,
    ChannelWrite.historyNotMoved => l10n.channels_writeHistoryNotMoved,
  };
  if (message == null) return false;
  showChannelBlockedMessage(context, message);
  return true;
}

/// Asks what a key change does with [channelName]'s message history: kept
/// under the new key, or deleted. Null means the user backed out, and nothing
/// may be written (#1128).
Future<KeyChangeHistory?> askKeyChangeHistory(
  BuildContext context,
  String channelName,
) {
  return showDialog<KeyChangeHistory>(
    context: context,
    builder: (dialogContext) {
      final l10n = dialogContext.l10n;
      return AlertDialog(
        title: Text(l10n.channels_keyChangeHistoryTitle),
        content: Text(l10n.channels_keyChangeHistoryBody(channelName)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l10n.common_cancel),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            onPressed: () =>
                Navigator.pop(dialogContext, KeyChangeHistory.delete),
            child: Text(l10n.channels_keyChangeDeleteHistory),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, KeyChangeHistory.keep),
            child: Text(l10n.channels_keyChangeKeepHistory),
          ),
        ],
      );
    },
  );
}

/// Refuses a second Public channel, and says so. Returns true if it refused.
///
/// Public is identified by its PSK (`Channel.isPublicChannel`), not by name or
/// slot, so this finds it wherever older firmware left it.
bool refusePublicAlreadyOnRadio(
  BuildContext context,
  MeshCoreConnector connector,
) {
  if (!connector.channels.any((c) => c.isPublicChannel)) return false;
  showChannelBlockedMessage(context, context.l10n.channels_publicAlreadyAdded);
  return true;
}

/// For a delete: refuses to remove Public, and says so. Returns true if it
/// refused. Firmware #1896 refuses the clear anyway, with the same error code
/// as an occupied slot, so without this the user would read the wrong reason
/// (owner 2026-10-28: "make sure Public can't be deleted").
bool refuseDeletingPublic(BuildContext context, Channel channel) {
  if (!channel.isPublicChannel) return false;
  showChannelBlockedMessage(
    context,
    context.l10n.channels_publicCannotBeRemoved,
  );
  return true;
}

/// For an edit or delete: refuses while the channel list is being re-read or
/// a write is unanswered, and says so. Returns true if it refused.
///
/// Replies are matched to commands by order, so a write sent during a sync
/// could take one of the sync's replies as its own.
bool refuseWhileChannelTableBusy(
  BuildContext context,
  MeshCoreConnector connector,
) {
  if (!connector.isChannelTableBusy) return false;
  showChannelBlockedMessage(context, context.l10n.channels_slotBusySyncing);
  return true;
}
