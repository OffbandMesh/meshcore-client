import 'dart:typed_data';

import 'contact.dart';

const int recentAttemptDiversityWindow = 2;

class PathSelection {
  final List<int> pathBytes;

  /// TRUE hop count (number of hops), or -1 for flood. NOT a byte count.
  /// `pathBytes.length == hopCount * hashWidth` for a routed selection.
  final int hopCount;

  /// Bytes per hop hash (1..3). Defaults to 1 (legacy single-byte). Sent on the
  /// wire packed with the hop count via `encodePathLen`. Without this, routed
  /// sends went out at width 1 and a 2-byte route was read as twice as many
  /// 1-byte hops, routing to the wrong nodes (#279).
  final int hashWidth;

  final bool useFlood;

  const PathSelection({
    required this.pathBytes,
    required this.hopCount,
    this.hashWidth = 1,
    required this.useFlood,
  });
}

/// Resolves the path to send to [contact], as a (bytes, true-hop-count, width)
/// triple. The contact's own `pathHashWidth` is the single width authority for
/// every non-flood branch, so an override, a device path, and a path-history
/// retry all encode at the width the route was actually captured at.
PathSelection resolvePathSelection(
  Contact contact, {
  PathSelection? selection,
  bool forceFlood = false,
}) {
  final width = contact.pathHashWidth < 1 ? 1 : contact.pathHashWidth;

  // Hops for a byte array at [width]; integer division tolerates a malformed
  // length rather than throwing.
  int hopsFor(List<int> bytes) =>
      width > 0 ? bytes.length ~/ width : bytes.length;

  if (contact.pathOverride != null) {
    if (contact.pathOverride! < 0) {
      return const PathSelection(pathBytes: [], hopCount: -1, useFlood: true);
    }
    final bytes = contact.pathOverrideBytes ?? Uint8List(0);
    return PathSelection(
      pathBytes: bytes,
      hopCount: hopsFor(bytes),
      hashWidth: width,
      useFlood: false,
    );
  }

  if (forceFlood || contact.pathLength < 0 || selection?.useFlood == true) {
    return const PathSelection(pathBytes: [], hopCount: -1, useFlood: true);
  }

  // Path-history retry: reuse the bytes, but derive hops/width from THIS
  // contact so the wire encoding matches the contact's configured width.
  if (selection != null && selection.pathBytes.isNotEmpty) {
    return PathSelection(
      pathBytes: selection.pathBytes,
      hopCount: hopsFor(selection.pathBytes),
      hashWidth: width,
      useFlood: false,
    );
  }

  return PathSelection(
    pathBytes: contact.path,
    hopCount: contact.pathLength,
    hashWidth: width,
    useFlood: false,
  );
}
