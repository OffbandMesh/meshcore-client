/// Crockford Base32, as used by the PocketMesh / MeshCore One reaction format.
///
/// Encode-only: a reaction hash is compared as a string and never decoded back
/// to bytes. The alphabet omits i, l, o and u to avoid visual ambiguity.
class CrockfordBase32 {
  static const String alphabet = '0123456789abcdefghjkmnpqrstvwxyz';

  /// Encode exactly 5 bytes (40 bits) as 8 characters, most significant first.
  ///
  /// Accumulates at most 12 bits at a time rather than packing all 40 into one
  /// int: bitwise operators are 32-bit on the web target, so a 40-bit shift
  /// would silently truncate there.
  static String encode5(List<int> bytes) {
    if (bytes.length != 5) {
      throw ArgumentError.value(
        bytes.length,
        'bytes',
        'Crockford Base32 encode5 needs exactly 5 bytes',
      );
    }
    final out = StringBuffer();
    var buffer = 0;
    var bits = 0;
    for (final byte in bytes) {
      buffer = (buffer << 8) | byte;
      bits += 8;
      while (bits >= 5) {
        bits -= 5;
        out.write(alphabet[(buffer >> bits) & 0x1F]);
      }
    }
    return out.toString();
  }

  /// The lowercase canonical form of an 8-character hash, or null if [text] is
  /// not valid Crockford Base32.
  ///
  /// Resolves the ambiguity aliases the format defines on input (O to 0, I and
  /// L to 1, either case) so a sender that emits them still matches. `u` has no
  /// alias and is rejected.
  static String? normalize8(String text) {
    if (text.length != 8) return null;
    final out = StringBuffer();
    for (var i = 0; i < 8; i++) {
      final lower = text[i].toLowerCase();
      final resolved = switch (lower) {
        'o' => '0',
        'i' || 'l' => '1',
        _ => lower,
      };
      if (!alphabet.contains(resolved)) return null;
      out.write(resolved);
    }
    return out.toString();
  }
}
