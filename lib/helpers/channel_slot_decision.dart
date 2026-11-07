import '../models/channel.dart';

/// Why a channel slot could not be allocated.
enum ChannelSlotRefusal {
  /// The channel list is mid-rewrite, so no slot can be trusted to be free.
  syncing,

  /// Every slot on the radio is in use.
  full,
}

/// Either a slot that is safe to write, or the reason it was refused.
class ChannelSlotDecision {
  const ChannelSlotDecision.slot(int this.slot) : refusal = null;
  const ChannelSlotDecision.refused(ChannelSlotRefusal this.refusal)
    : slot = null;

  final int? slot;
  final ChannelSlotRefusal? refusal;

  bool get isAllowed => slot != null;
}

/// Decide which channel slot a new channel may occupy (#1021).
///
/// Pulled out of the channels screen so it can be tested without a widget, and
/// so the QR and config-import paths can share one answer instead of each
/// carrying their own (there were three divergent implementations, and only one
/// of them had the bug).
///
/// Two refusals, both deliberate:
///
/// * [isSyncing] true means the connector has emptied its channel list and is
///   refilling it slot by slot. Any index would look free. Choosing one here is
///   what overwrote Public: a slot picked during a sync pointed at an occupied
///   slot by the time it was written.
/// * No free index means the radio is full. The caller must be told, never
///   handed slot 0 as a consolation, which is the old `return 0` bug and is
///   where Public normally lives.
///
/// Callers pass the connector's `isChannelTableBusy` (a sync, or a write the
/// radio has not answered yet), not `hasLoadedChannels`: the latter stays false
/// after a *failed* sync while the cached list is restored into use, so gating
/// on it would refuse forever on a flaky link.
///
/// An absent index genuinely means a free slot, because the connector never
/// adds an empty channel to its list.
///
/// Slot 0 is Public's (firmware #1896, owner 2026-10-28: slot 0 "should always
/// remain public"). Firmware refuses any other channel there, even while it is
/// empty, so [isPublic] false never gets slot 0. Public goes to slot 0 when it
/// is free; firmware refuses Public anywhere else, so the fallback to another
/// free slot exists only for older firmware, where slot 0 can be held by some
/// other channel. [isPublic] is required so no caller can forget the rule.
ChannelSlotDecision decideChannelSlot({
  required List<Channel> channels,
  required int maxChannels,
  required bool isSyncing,
  required bool isPublic,
}) {
  if (isSyncing) {
    return const ChannelSlotDecision.refused(ChannelSlotRefusal.syncing);
  }
  final used = channels.map((c) => c.index).toSet();
  if (isPublic && !used.contains(Channel.publicSlot)) {
    return const ChannelSlotDecision.slot(Channel.publicSlot);
  }
  for (var i = 0; i < maxChannels; i++) {
    if (i == Channel.publicSlot) continue;
    if (!used.contains(i)) return ChannelSlotDecision.slot(i);
  }
  return const ChannelSlotDecision.refused(ChannelSlotRefusal.full);
}
