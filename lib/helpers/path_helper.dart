import '../models/contact.dart';
import '../connector/meshcore_protocol.dart';

class PathHelper {
  /// Path bytes as comma-separated hops, each hop [hashWidth] bytes of hex. (#154)
  static String formatPathHex(List<int> pathBytes, int hashWidth) {
    return _hopGroups(pathBytes, hashWidth).map(_hopHex).join(',');
  }

  /// Resolves each [hashWidth]-byte hop to a repeater/room name, falling back to
  /// the hop's hex prefix when no contact matches. (#154)
  static String resolvePathNames(
    List<int> pathBytes,
    List<Contact> allContacts,
    int hashWidth,
  ) {
    return _hopGroups(pathBytes, hashWidth)
        .map((hop) {
          final matches = allContacts
              .where(
                (c) =>
                    c.publicKey.length >= hop.length &&
                    _startsWith(c.publicKey, hop) &&
                    (c.type == advTypeRepeater || c.type == advTypeRoom),
              )
              .toList();
          if (matches.isEmpty) return _hopHex(hop);
          if (matches.length == 1) return matches.first.name;
          return matches.map((c) => c.name).join(' | ');
        })
        .join(' → ');
  }

  /// Splits [pathBytes] into hops of [hashWidth] bytes (a trailing partial hop,
  /// from a malformed path, is kept rather than dropped).
  static List<List<int>> _hopGroups(List<int> pathBytes, int hashWidth) {
    final w = hashWidth < 1 ? 1 : hashWidth;
    final hops = <List<int>>[];
    for (var i = 0; i < pathBytes.length; i += w) {
      hops.add(
        pathBytes.sublist(
          i,
          i + w > pathBytes.length ? pathBytes.length : i + w,
        ),
      );
    }
    return hops;
  }

  static String _hopHex(List<int> hop) =>
      hop.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join();

  static bool _startsWith(List<int> pubkey, List<int> prefix) {
    for (var i = 0; i < prefix.length; i++) {
      if (pubkey[i] != prefix[i]) return false;
    }
    return true;
  }

  /// Trace `path_sz` flag for a configured hash width: floor(log2(width)), so
  /// width 1→0, 2→1, 3→1, 4→2. The wire hop size is `1 << path_sz` bytes, the
  /// firmware's trace widths are powers of two, so this is the largest power of
  /// two ≤ the configured width (width 3 sends the leading 2 bytes per hop). (#150)
  static int tracePathSz(int hashWidth) {
    var w = hashWidth < 1 ? 1 : hashWidth;
    var sz = 0;
    while (w > 1) {
      w >>= 1;
      sz++;
    }
    return sz;
  }

  /// Bytes per trace hop on the wire = `1 << tracePathSz`. (#150)
  static int traceHopBytes(int hashWidth) => 1 << tracePathSz(hashWidth);

  /// Packs [width] bytes of [bytes] from [start] into a big-endian int, used to
  /// key trace hops by their full configured-width prefix. (#150)
  static int packPrefix(List<int> bytes, int start, int width) {
    var v = 0;
    for (var i = 0; i < width; i++) {
      v = (v << 8) | bytes[start + i];
    }
    return v;
  }

  /// Splits trace [pathData] into packed big-endian hops of [hopBytes] each. A
  /// trailing partial hop (malformed) is dropped. (#150)
  static List<int> tracePathHops(List<int> pathData, int hopBytes) {
    final hb = hopBytes < 1 ? 1 : hopBytes;
    final hops = <int>[];
    for (var i = 0; i + hb <= pathData.length; i += hb) {
      hops.add(packPrefix(pathData, i, hb));
    }
    return hops;
  }

  /// Builds the trace round-trip payload for a non-empty routing path:
  /// out-hops + (target prefix, when [throughTarget]) + reversed out-hops, each
  /// hop the leading [hopBytes] of a [routingWidth]-byte routing hop. Mirrors by
  /// hop, not by byte, so multi-byte hops stay intact. For a chat target the far
  /// hop is the turnaround and is not duplicated. (#150)
  static List<int> buildTraceRoundTrip({
    required List<int> routingPath,
    required int routingWidth,
    required int hopBytes,
    required bool throughTarget,
    required List<int> targetPrefix,
  }) {
    final rw = routingWidth < 1 ? 1 : routingWidth;
    final hb = hopBytes < 1 ? 1 : hopBytes;
    final hops = <List<int>>[];
    for (var i = 0; i + rw <= routingPath.length; i += rw) {
      hops.add(routingPath.sublist(i, i + (hb < rw ? hb : rw)));
    }
    final out = <int>[];
    for (final h in hops) {
      out.addAll(h);
    }
    if (throughTarget) {
      out.addAll(targetPrefix);
      for (final h in hops.reversed) {
        out.addAll(h);
      }
    } else if (hops.length >= 2) {
      for (final h in hops.reversed.skip(1)) {
        out.addAll(h);
      }
    }
    return out;
  }
}
