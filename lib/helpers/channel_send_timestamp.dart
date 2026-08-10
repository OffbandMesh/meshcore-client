/// Returns a channel-send timestamp (Unix seconds) strictly greater than
/// [lastSecs] for the same channel, so no two sends on one channel ever share a
/// `(ts, channel_idx)` key.
///
/// This is a correctness requirement for the 0xC6 packet-hash correlation
/// (#524/#611): `msg_timestamp` is only second-resolution and MeshCore channel
/// encryption is deterministic (AES-128-ECB), so two different messages on the
/// same channel within one second would otherwise map to the same key but
/// different hashes, and the client would query CoreScope with the wrong hash.
///
/// Uses [nowSecs] unless it would collide with or precede [lastSecs], in which
/// case it bumps to `lastSecs + 1`. Mirrors the firmware's own
/// `getCurrentTimeUnique()`.
int monotonicChannelSendTs(int nowSecs, int? lastSecs) {
  if (lastSecs != null && nowSecs <= lastSecs) return lastSecs + 1;
  return nowSecs;
}
