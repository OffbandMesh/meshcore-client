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
    // isSyncingChannels, not hasLoadedChannels: the latter stays false after a
    // FAILED sync while the cached list is restored, so gating on it would make
    // adding a channel impossible on a flaky link.
    isSyncing: connector.isSyncingChannels,
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
