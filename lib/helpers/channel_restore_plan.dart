import '../models/channel.dart';

/// One channel to write back to the radio, and where.
class ChannelRestoreStep {
  const ChannelRestoreStep({
    required this.channel,
    required this.slot,
    required this.clearFirst,
  });

  final Channel channel;
  final int slot;

  /// The slot holds an erased record. Firmware treats that as occupied
  /// (#1865), so it is cleared before the channel is written.
  final bool clearFirst;
}

/// What a restore achieved, as the radio reported it.
class ChannelRestoreResult {
  const ChannelRestoreResult({
    required this.confirmed,
    required this.total,
    required this.notRestored,
  });

  /// Channels the radio confirmed taking.
  final int confirmed;

  /// Channels the restore set out to put back.
  final int total;

  /// Channels the radio refused or never answered for, or had no room for.
  final List<Channel> notRestored;
}

class ChannelRestorePlan {
  const ChannelRestorePlan(this.steps, this.noRoom);

  final List<ChannelRestoreStep> steps;

  /// Cached channels with no slot left to go to.
  final List<Channel> noRoom;
}

/// Decides how to put a radio's lost channels back (#1060, #1117).
///
/// The client's cached list says which channels the radio had. Replaying each
/// one into its remembered slot no longer works on current firmware, which
/// refuses a channel over an occupied slot (#1865), treats an erased record
/// as occupied, refuses any channel but Public in slot 0, and refuses Public
/// anywhere else (#1896). So this places by identity:
///
/// * A cached channel whose key is already live on the radio, in any slot, is
///   left out: the radio has it.
/// * Public goes to slot 0. If slot 0 holds a live channel (older firmware
///   only), Public takes a free slot instead, so nothing is overwritten.
/// * Any other channel goes back to its remembered slot when that slot is
///   free or erased and is not slot 0; otherwise to the lowest free slot.
/// * A live channel is never a destination, so nothing on the radio is
///   overwritten.
/// * An erased slot is cleared first.
///
/// Order does not matter: nothing but Public is ever placed in slot 0, so
/// Public always finds it free unless a live channel holds it.
ChannelRestorePlan planChannelRestore({
  required List<Channel> cached,
  required List<Channel> live,
  required Set<int> erasedSlots,
  required int maxChannels,
}) {
  final liveKeys = live.map((c) => c.pskHex).toSet();
  final taken = live.map((c) => c.index).toSet();
  final candidates = cached
      .where((c) => !c.isUnusable && !liveKeys.contains(c.pskHex))
      .toList();

  final steps = <ChannelRestoreStep>[];
  final noRoom = <Channel>[];
  final placedKeys = <String>{};

  bool free(int slot) =>
      slot >= 0 && slot < maxChannels && !taken.contains(slot);

  int? firstFree() {
    for (var i = 0; i < maxChannels; i++) {
      if (i == Channel.publicSlot) continue;
      if (free(i)) return i;
    }
    return null;
  }

  for (final channel in candidates) {
    // A cache can hold the same key twice; write it once.
    if (!placedKeys.add(channel.pskHex)) continue;
    final int? slot;
    if (channel.isPublicChannel) {
      slot = free(Channel.publicSlot) ? Channel.publicSlot : firstFree();
    } else if (channel.index != Channel.publicSlot && free(channel.index)) {
      slot = channel.index;
    } else {
      slot = firstFree();
    }
    if (slot == null) {
      noRoom.add(channel);
      continue;
    }
    taken.add(slot);
    steps.add(
      ChannelRestoreStep(
        channel: channel,
        slot: slot,
        clearFirst: erasedSlots.contains(slot),
      ),
    );
  }
  return ChannelRestorePlan(steps, noRoom);
}
