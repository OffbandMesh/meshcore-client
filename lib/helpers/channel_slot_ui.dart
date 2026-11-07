import 'package:flutter/material.dart';

import '../connector/meshcore_connector.dart';
import '../l10n/l10n.dart';
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
int? allocateChannelSlotOrExplain(
  BuildContext context,
  MeshCoreConnector connector,
) {
  final decision = decideChannelSlot(
    channels: connector.channels,
    maxChannels: connector.maxChannels,
    // Not hasLoadedChannels: that stays false after a FAILED sync while the
    // cached list is restored, so gating on it would make adding a channel
    // impossible on a flaky link. Busy also covers a write the radio has not
    // answered yet (#1026): until it does, the list does not show its slot.
    isSyncing: connector.isChannelTableBusy,
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
  };
  if (message == null) return false;
  showChannelBlockedMessage(context, message);
  return true;
}

/// Refuses a second Public channel, and says so. Returns true if it refused.
///
/// Public is identified by its PSK (`Channel.isPublicChannel`), not by slot 0,
/// so it can live in any slot and this is the only duplicate check it needs.
bool refusePublicAlreadyOnRadio(
  BuildContext context,
  MeshCoreConnector connector,
) {
  if (!connector.channels.any((c) => c.isPublicChannel)) return false;
  showChannelBlockedMessage(context, context.l10n.channels_publicAlreadyAdded);
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
