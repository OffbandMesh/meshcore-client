// Shared `cc|` correlation grammar (#882): one allocator and one splitter for
// every CLI path — the repeater text-message CLI (RepeaterCommandService) and
// the local frame-66 console (LocalCliService). The grammar is the device's:
// a 3-char token ending in `|`, reflected at the start of the reply when the
// command carried one.

/// Allocates `XX|` correlation tokens: two uppercase hex digits and a pipe,
/// cycling through 256 values and skipping any currently in flight.
class PrefixAllocator {
  int _counter = 0;

  String next(Set<String> inUse) {
    for (var i = 0; i < 256; i++) {
      final value = _counter++ & 0xFF;
      final token =
          '${value.toRadixString(16).padLeft(2, '0').toUpperCase()}|';
      if (!inUse.contains(token)) return token;
    }
    return '00|';
  }
}

/// A reply split into its reflected correlation token and payload.
class Correlated {
  const Correlated({required this.prefix, required this.payload});

  final String? prefix;
  final String payload;
}

/// Splits [raw] on the positional prefix rule (third character `|`). The
/// payload keeps its leading whitespace trimmed, matching the repeater path's
/// long-standing behavior.
Correlated splitCorrelated(String raw) {
  if (raw.length >= 3 && raw[2] == '|') {
    return Correlated(
      prefix: raw.substring(0, 3),
      payload: raw.substring(3).trimLeft(),
    );
  }
  return Correlated(prefix: null, payload: raw);
}
