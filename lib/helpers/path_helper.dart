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
}
