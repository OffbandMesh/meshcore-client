// Wire codec for the Offband config companion command (CMD_OFFBAND_CONFIG 0xC0).
//
// Mirrors the firmware contract in the firmware repo's
// `examples/companion_radio/OffbandConfigProtocol.h` + `MyMesh::handleOffbandConfigCmd`
// (Epic F #160-#163) byte-for-byte. This is a PURE codec: it builds request
// frames and parses response frames. It never touches BLE/USB/TCP, the
// connector sends the Uint8Lists and feeds received frames back to [parse].
//
// Frame layout (both directions): byte[0] = code (0xC0), byte[1] = sub-type,
// byte[2..] = payload. All payloads are ASCII/UTF-8 text, NUL-terminated;
// numerics are decimal strings, transport/auth_type are the wire enum names.

import 'dart:convert';
import 'dart:typed_data';

import '../models/observer_config.dart';

/// One decoded Offband-config response frame.
sealed class ConfigResponse {
  const ConfigResponse();
}

/// SET succeeded; [text] is the firmware's human confirmation line.
class ConfigAck extends ConfigResponse {
  const ConfigAck(this.text);
  final String text;
}

/// Any op failed; [text] is the error message (firmware lines start "ERROR").
class ConfigErr extends ConfigResponse {
  const ConfigErr(this.text);
  final String text;
}

/// GET succeeded. [text] is the raw reply ("key = value\n"); [value] extracts
/// the value (everything after the first " = ", newline-trimmed).
class ConfigValue extends ConfigResponse {
  const ConfigValue(this.text);
  final String text;

  String get value => ObserverConfigClient.extractScalarValue(text);
}

/// Start of a broker-pool dump; [count] populated slots follow.
class ConfigBrokersStart extends ConfigResponse {
  const ConfigBrokersStart(this.count);
  final int count;
}

/// One broker field line: slot + key + value (already split on the first '=').
class ConfigBrokerKv extends ConfigResponse {
  const ConfigBrokerKv(this.slot, this.key, this.value);
  final int slot;
  final String key;
  final String value;
}

/// End of a broker-pool dump.
class ConfigBrokersEnd extends ConfigResponse {
  const ConfigBrokersEnd();
}

/// Start of a chunked VIEW text dump.
class ConfigViewStart extends ConfigResponse {
  const ConfigViewStart();
}

/// One VIEW text chunk.
class ConfigViewChunk extends ConfigResponse {
  const ConfigViewChunk(this.text);
  final String text;
}

/// End of a VIEW text dump.
class ConfigViewEnd extends ConfigResponse {
  const ConfigViewEnd();
}

/// Frame that is not an Offband-config response (wrong code) or an
/// unrecognized sub-type. [subType] is byte[1] (or -1 if too short / wrong code).
class ConfigUnknown extends ConfigResponse {
  const ConfigUnknown(this.subType);
  final int subType;
}

class ObserverConfigClient {
  ObserverConfigClient._();

  // --- Frame codes ----------------------------------------------------------
  /// Request & response frame byte[0].
  static const int cmdConfig = 0xC0;
  static const int respConfig = 0xC0;

  /// Command exists iff FIRMWARE_VER_CODE >= this AND the capability bit is set.
  static const int minVerCode = 14;

  /// Bit 0 of the `offband_caps` byte appended to the device-info reply.
  static const int capWifiObserver = 0x01;

  // Request sub-type, byte[1].
  static const int opSet = 0x00;
  static const int opGet = 0x01;
  static const int opView = 0x02;
  static const int opBrokers = 0x03;

  // Response sub-type, byte[1].
  static const int rAck = 0x00;
  static const int rErr = 0x01;
  static const int rValue = 0x02;
  static const int rBrokersStart = 0x10;
  static const int rBrokerKv = 0x11;
  static const int rBrokersEnd = 0x12;
  static const int rViewStart = 0x20;
  static const int rViewChunk = 0x21;
  static const int rViewEnd = 0x22;

  /// Number of MQTT broker slots (firmware OFFBAND_MAX_BROKERS).
  static const int brokerSlotCount = 10;

  /// True iff the device advertises config support: version gate AND the
  /// `OFFBAND_CAP_WIFI_OBSERVER` bit in the device-info `offband_caps` byte.
  /// The WHOLE command (display included) is observer-gated, so both must hold.
  static bool supportsConfig({
    required int firmwareVerCode,
    required int offbandCaps,
  }) {
    return firmwareVerCode >= minVerCode &&
        (offbandCaps & capWifiObserver) != 0;
  }

  // --- Request builders -----------------------------------------------------

  static Uint8List _frame(int op, [String? payload]) {
    final builder = BytesBuilder();
    builder.addByte(cmdConfig);
    builder.addByte(op);
    if (payload != null) {
      builder.add(utf8.encode(payload));
      builder.addByte(0); // NUL-terminate (firmware NUL-terminates on receive)
    }
    return builder.toBytes();
  }

  /// SET `<key> <value>`, firmware splits on the FIRST space; [value] is the
  /// verbatim remainder and may contain spaces.
  static Uint8List buildSet(String key, String value) =>
      _frame(opSet, '$key $value');

  /// GET `<key>` → one [ConfigValue] frame ("key = value").
  static Uint8List buildGet(String key) => _frame(opGet, key);

  /// VIEW read-only selector. Firmware allowlist: `mqtt status`,
  /// `mqtt view <N>`, `wifi status`. Anything else is rejected.
  static Uint8List buildView(String selector) => _frame(opView, selector);

  /// Paginated broker-pool dump (no payload) → START → KV* → END.
  static Uint8List buildBrokers() => _frame(opBrokers);

  /// Convenience: SET one broker field, `mqtt.broker.<slot>.<field>`.
  static Uint8List buildBrokerFieldSet(int slot, String field, String value) =>
      buildSet('mqtt.broker.$slot.$field', value);

  /// The ordered field SETs to (re)configure a broker slot's non-secret +
  /// secret fields. Caller sends each, awaiting its ACK.
  ///
  /// NOTE: `enabled` is intentionally NOT here. The firmware
  /// `handleSetBrokerField` has no `enabled` branch and the VIEW allowlist
  /// blocks `mqtt enable/disable/clear`, so activation + clear have no wire
  /// path in this firmware (TODO: firmware F-task, see observer_config docs).
  /// The activation guard still holds: any field SET on a live slot
  /// auto-disables it firmware-side.
  static List<MapEntry<String, String>> brokerFieldSets(
    BrokerConfig b, {
    SecretField password = const SecretField.unchanged(),
  }) {
    final p = 'mqtt.broker.${b.slot}';
    final out = <MapEntry<String, String>>[
      MapEntry('$p.url', b.url),
      MapEntry('$p.port', '${b.port}'),
      MapEntry('$p.transport', b.transport.wire),
      MapEntry('$p.auth_type', b.authType.wire),
      MapEntry('$p.username', b.username),
      MapEntry('$p.topic_prefix', b.topicPrefix),
      MapEntry('$p.iata_override', b.iataOverride),
      MapEntry('$p.jwt_audience', b.jwtAudience),
      MapEntry('$p.jwt_refresh', '${b.jwtRefresh}'),
      MapEntry('$p.jwt_owner', b.jwtOwner),
      MapEntry('$p.jwt_email', b.jwtEmail),
      MapEntry('$p.ca_cert', b.caCert),
    ];
    switch (password) {
      case SecretSet(:final value):
        out.add(MapEntry('$p.password', value));
      case SecretClear():
        out.add(MapEntry('$p.password', ''));
      case SecretUnchanged():
        break;
    }
    return out;
  }

  // --- Response parsing -----------------------------------------------------

  /// Decode one response frame into a typed [ConfigResponse].
  static ConfigResponse parse(Uint8List f) {
    if (f.length < 2 || f[0] != respConfig) return const ConfigUnknown(-1);
    switch (f[1]) {
      case rAck:
        return ConfigAck(_text(f, 2));
      case rErr:
        return ConfigErr(_text(f, 2));
      case rValue:
        return ConfigValue(_text(f, 2));
      case rBrokersStart:
        return ConfigBrokersStart(f.length > 2 ? f[2] : 0);
      case rBrokerKv:
        // Reject out-of-range slots from a hostile device (contract: 0..N-1).
        if (f.length < 3 || f[2] >= brokerSlotCount) {
          return const ConfigUnknown(rBrokerKv);
        }
        final body = _text(f, 3);
        final eq = body.indexOf(
          '=',
        ); // split on FIRST '=' (value may contain '=')
        if (eq < 0) return ConfigBrokerKv(f[2], body, '');
        return ConfigBrokerKv(
          f[2],
          body.substring(0, eq),
          body.substring(eq + 1),
        );
      case rBrokersEnd:
        return const ConfigBrokersEnd();
      case rViewStart:
        return const ConfigViewStart();
      case rViewChunk:
        return ConfigViewChunk(_text(f, 2));
      case rViewEnd:
        return const ConfigViewEnd();
      default:
        return ConfigUnknown(f[1]);
    }
  }

  /// Extract the value from a scalar reply (`key = value` -> `value`).
  ///
  /// Splits on the FIRST `=` (config keys never contain `=`; values may). A
  /// blank field replies `key =` with nothing after the `=`, so the old
  /// ` = ` (space-equals-space) match failed and leaked the whole `key =` line
  /// as the value (#469). Splitting on `=` and trimming handles blank values
  /// (-> empty) and values containing `=` correctly.
  static String extractScalarValue(String reply) {
    final line = reply.replaceAll('\n', '');
    final i = line.indexOf('=');
    return i < 0 ? line.trim() : line.substring(i + 1).trim();
  }

  /// Read a NUL-terminated UTF-8 string from [f] starting at [start].
  static String _text(Uint8List f, int start) {
    if (start >= f.length) return '';
    var end = start;
    while (end < f.length && f[end] != 0) {
      end++;
    }
    return utf8.decode(f.sublist(start, end), allowMalformed: true);
  }
}

/// Accumulates a broker-pool dump (START → KV* → END) into typed
/// [BrokerConfig]s. Feed each parsed [ConfigResponse]; [add] returns the
/// decoded list once END arrives (or `[]` for an empty pool), else null.
class BrokerListDecoder {
  /// Hard cap on total key/value lines retained across the whole dump, a
  /// hostile device cannot grow memory without bound (Gemini BLOCKER: DoS).
  /// Generous for the 10-slot contract (~16 fields each).
  static const int _maxFields = ObserverConfigClient.brokerSlotCount * 32;

  final Map<int, Map<String, String>> _slots = {};
  bool _open = false;
  int _fields = 0;

  /// Feed one response. Returns the broker list on END, else null.
  /// Anything before START or after END is ignored.
  List<BrokerConfig>? add(ConfigResponse r) {
    switch (r) {
      case ConfigBrokersStart():
        _slots.clear();
        _fields = 0;
        _open = true;
        return null;
      case ConfigBrokerKv(:final slot, :final key, :final value):
        // Drop out-of-range slots and stop accumulating past the field cap.
        if (_open &&
            slot >= 0 &&
            slot < ObserverConfigClient.brokerSlotCount &&
            _fields < _maxFields) {
          (_slots[slot] ??= {})[key] = value;
          _fields++;
        }
        return null;
      case ConfigBrokersEnd():
        if (!_open) return null;
        _open = false;
        final list =
            _slots.entries
                .map((e) => BrokerConfig.fromWireFields(e.key, e.value))
                .toList()
              ..sort((a, b) => a.slot.compareTo(b.slot));
        return list;
      default:
        return null;
    }
  }

  /// True while a dump is in progress (START seen, END not yet).
  bool get inProgress => _open;
}
