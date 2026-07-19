import 'dart:math';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

import 'prefs_manager.dart';

/// Per-install client identity sent in `CMD_APP_START` (#297).
///
/// Wadamesh keeps a per-client history watermark (`last_delivered_seq`) keyed by
/// this id. Without one we land in the shared empty-string slot alongside every
/// other MeshCore client on the machine, so whichever app connects first drains
/// the device's history ring and the next app is told "no more messages" for
/// frames it never received.
///
/// The id is exactly [length] bytes so a single frame satisfies both firmwares:
/// stock treats `cmd_frame[1..7]` as reserved and reads the app name at a fixed
/// offset 8, while Wadamesh reads it at `2 + cid_len`. With `cid_len == 6` both
/// land on 8.
class ClientIdStore {
  static const String _key = 'client_install_id';

  /// Byte length of the id. Do not change without re-checking both firmwares —
  /// 6 is what keeps the app-name offset agreeing at 8.
  static const int length = 6;

  /// The install's client id, generated and persisted on first use so it is
  /// stable across builds (all builds share one SharedPreferences store).
  static Uint8List load() {
    final prefs = PrefsManager.instance;
    final stored = prefs.getString(_key);
    if (stored != null && stored.length == length * 2) {
      final bytes = Uint8List(length);
      for (var i = 0; i < length; i++) {
        final byte = int.tryParse(
          stored.substring(i * 2, i * 2 + 2),
          radix: 16,
        );
        if (byte == null) {
          return _generate(prefs);
        }
        bytes[i] = byte;
      }
      return bytes;
    }
    return _generate(prefs);
  }

  static Uint8List _generate(SharedPreferences prefs) {
    final random = Random.secure();
    final bytes = Uint8List(length);
    for (var i = 0; i < length; i++) {
      bytes[i] = random.nextInt(256);
    }
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    prefs.setString(_key, hex);
    return bytes;
  }
}
