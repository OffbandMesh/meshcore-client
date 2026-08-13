/// MeshCore stock companion config export format (#572, epic #568).
///
/// This is a faithful model of the JSON file the official MeshCore Companion
/// app writes from its Export Config screen, so that a stock export imports
/// into Offband and an Offband export imports into stock. The shape was
/// reverse-engineered from ten real exports across five radios (2359 contacts,
/// 76 channels); the evidence is recorded on issue #569.
///
/// Rules the format imposes, none of them obvious:
///
/// * **There is no version field.** Stock writes none, so we write none, and
///   validation is by shape alone. Every top-level section is independently
///   optional because the export screen lets the user deselect any of them.
/// * `public_key` and `private_key` are one unit: stock's single "Private
///   Identity Key" control emits both or neither.
/// * `radio_settings` mixes units: `frequency` is kHz, `bandwidth` is Hz, and
///   `coding_rate` is a bare denominator (5 means 4/5).
/// * Latitudes and longitudes are JSON **strings**, never numbers.
/// * `channels` has no index field; array position is the channel index.
/// * Contact timestamps are whatever the mesh reported and are not sanitized.
///   The real corpus contains values from epoch 14 to the year 2095.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../connector/meshcore_protocol.dart' show pubKeyToHex;

/// Thrown when a config file does not match the stock format.
///
/// Carries the offending JSON path so an import screen can tell the user which
/// part of the file is wrong rather than just "invalid file".
class StockConfigFormatException implements Exception {
  StockConfigFormatException(this.message, {this.path});

  final String message;

  /// Dotted path to the offending value, e.g. `contacts[3].out_path_list`.
  final String? path;

  @override
  String toString() => path == null
      ? 'StockConfigFormatException: $message'
      : 'StockConfigFormatException at $path: $message';
}

/// Firmware caps a contact name at `char name[32]`, so 31 usable characters.
const int kStockMaxContactNameChars = 31;

const int _publicKeyBytes = 32;
const int _privateKeyBytes = 64;
const int _channelSecretBytes = 16;

/// Hop-hash widths the parser will accept, in bytes.
///
/// Only width 2 has been observed in the wild (a single path across the whole
/// corpus). 1 and 3 are accepted because the firmware path-length byte encodes
/// widths 1..3 (#309) and there is no reason stock would refuse to emit them.
/// Anything else is rejected rather than guessed at.
const Set<int> kStockPathHashWidths = {1, 2, 3};

Uint8List _parseHex(String value, String path, {int? expectBytes}) {
  if (value.length.isOdd) {
    throw StockConfigFormatException(
      'expected hex, got an odd number of characters (${value.length})',
      path: path,
    );
  }
  final bytes = Uint8List(value.length ~/ 2);
  for (var i = 0; i < bytes.length; i++) {
    final byte = int.tryParse(value.substring(i * 2, i * 2 + 2), radix: 16);
    if (byte == null) {
      throw StockConfigFormatException('expected hex characters', path: path);
    }
    bytes[i] = byte;
  }
  if (expectBytes != null && bytes.length != expectBytes) {
    throw StockConfigFormatException(
      'expected $expectBytes bytes, got ${bytes.length}',
      path: path,
    );
  }
  return bytes;
}

Map<String, dynamic> _asObject(Object? value, String path) {
  if (value is! Map) {
    throw StockConfigFormatException('expected an object', path: path);
  }
  return value.cast<String, dynamic>();
}

int _asInt(Object? value, String path) {
  if (value is int) return value;
  throw StockConfigFormatException('expected an integer', path: path);
}

bool _asBool(Object? value, String path) {
  if (value is bool) return value;
  throw StockConfigFormatException('expected a boolean', path: path);
}

String _asString(Object? value, String path) {
  if (value is String) return value;
  throw StockConfigFormatException('expected a string', path: path);
}

/// Stock writes coordinates as decimal strings, so `0.0` and `39.561991` both
/// appear verbatim. Dart's shortest-round-trip `double.toString()` reproduces
/// exactly that, which is why [_coordToJson] is a plain `toString`.
double _parseCoord(Object? value, String path) {
  final text = _asString(value, path);
  final parsed = double.tryParse(text);
  if (parsed == null) {
    throw StockConfigFormatException(
      'expected a decimal coordinate string',
      path: path,
    );
  }
  return parsed;
}

String _coordToJson(double value) => value.toString();

/// LoRa parameters. Units differ per field. See the class doc on [StockConfig].
class StockRadioSettings {
  const StockRadioSettings({
    required this.frequencyKhz,
    required this.bandwidthHz,
    required this.spreadingFactor,
    required this.codingRate,
    required this.txPower,
  });

  /// `frequency`, in **kHz** (910525 means 910.525 MHz).
  final int frequencyKhz;

  /// `bandwidth`, in **Hz** (62500 means 62.5 kHz).
  final int bandwidthHz;

  final int spreadingFactor;

  /// `coding_rate`, the **denominator only**, 5 means 4/5.
  final int codingRate;

  /// `tx_power`, in dBm.
  final int txPower;

  factory StockRadioSettings.fromJson(Map<String, dynamic> json, String path) {
    return StockRadioSettings(
      frequencyKhz: _asInt(json['frequency'], '$path.frequency'),
      bandwidthHz: _asInt(json['bandwidth'], '$path.bandwidth'),
      spreadingFactor: _asInt(
        json['spreading_factor'],
        '$path.spreading_factor',
      ),
      codingRate: _asInt(json['coding_rate'], '$path.coding_rate'),
      txPower: _asInt(json['tx_power'], '$path.tx_power'),
    );
  }

  Map<String, dynamic> toJson() => {
    'frequency': frequencyKhz,
    'bandwidth': bandwidthHz,
    'spreading_factor': spreadingFactor,
    'coding_rate': codingRate,
    'tx_power': txPower,
  };
}

/// The device's own advertised position. Both values are strings on the wire.
class StockPositionSettings {
  const StockPositionSettings({
    required this.latitude,
    required this.longitude,
  });

  final double latitude;
  final double longitude;

  factory StockPositionSettings.fromJson(
    Map<String, dynamic> json,
    String path,
  ) {
    return StockPositionSettings(
      latitude: _parseCoord(json['latitude'], '$path.latitude'),
      longitude: _parseCoord(json['longitude'], '$path.longitude'),
    );
  }

  Map<String, dynamic> toJson() => {
    'latitude': _coordToJson(latitude),
    'longitude': _coordToJson(longitude),
  };
}

/// Stock's "Other Settings". Both fields are ints on the wire even though they
/// read as booleans in the UI: `manual_add_contacts` is emitted as 0/1, not
/// true/false, unlike the [StockAutoAddSettings] block.
class StockOtherSettings {
  const StockOtherSettings({
    required this.manualAddContacts,
    required this.advertLocationPolicy,
  });

  final int manualAddContacts;

  /// Shown in stock's UI as "Share Position in Advert".
  final int advertLocationPolicy;

  factory StockOtherSettings.fromJson(Map<String, dynamic> json, String path) {
    return StockOtherSettings(
      manualAddContacts: _asInt(
        json['manual_add_contacts'],
        '$path.manual_add_contacts',
      ),
      advertLocationPolicy: _asInt(
        json['advert_location_policy'],
        '$path.advert_location_policy',
      ),
    );
  }

  Map<String, dynamic> toJson() => {
    'manual_add_contacts': manualAddContacts,
    'advert_location_policy': advertLocationPolicy,
  };
}

/// Stock's "Auto Add Settings". Booleans here really are JSON booleans.
class StockAutoAddSettings {
  const StockAutoAddSettings({
    required this.autoAddChat,
    required this.autoAddRepeater,
    required this.autoAddRoomServer,
    required this.autoAddSensor,
    required this.overwriteOldest,
    required this.autoAddMaxHops,
  });

  final bool autoAddChat;
  final bool autoAddRepeater;
  final bool autoAddRoomServer;
  final bool autoAddSensor;
  final bool overwriteOldest;

  /// `auto_add_max_hops`; stock renders 0 as "(no limit)".
  final int autoAddMaxHops;

  factory StockAutoAddSettings.fromJson(
    Map<String, dynamic> json,
    String path,
  ) {
    return StockAutoAddSettings(
      autoAddChat: _asBool(json['auto_add_chat'], '$path.auto_add_chat'),
      autoAddRepeater: _asBool(
        json['auto_add_repeater'],
        '$path.auto_add_repeater',
      ),
      autoAddRoomServer: _asBool(
        json['auto_add_room_server'],
        '$path.auto_add_room_server',
      ),
      autoAddSensor: _asBool(json['auto_add_sensor'], '$path.auto_add_sensor'),
      overwriteOldest: _asBool(
        json['overwrite_oldest'],
        '$path.overwrite_oldest',
      ),
      autoAddMaxHops: _asInt(
        json['auto_add_max_hops'],
        '$path.auto_add_max_hops',
      ),
    );
  }

  Map<String, dynamic> toJson() => {
    'auto_add_chat': autoAddChat,
    'auto_add_repeater': autoAddRepeater,
    'auto_add_room_server': autoAddRoomServer,
    'auto_add_sensor': autoAddSensor,
    'overwrite_oldest': overwriteOldest,
    'auto_add_max_hops': autoAddMaxHops,
  };
}

/// One channel. The array position in [StockConfig.channels] is the index:
/// the record itself carries no index field.
class StockChannel {
  const StockChannel({required this.name, required this.secret});

  final String name;

  /// The 16-byte PSK, hex on the wire.
  final Uint8List secret;

  factory StockChannel.fromJson(Map<String, dynamic> json, String path) {
    return StockChannel(
      name: _asString(json['name'], '$path.name'),
      secret: _parseHex(
        _asString(json['secret'], '$path.secret'),
        '$path.secret',
        expectBytes: _channelSecretBytes,
      ),
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'secret': pubKeyToHex(secret),
  };
}

/// A contact's routing path, as carried by `out_path_list`.
///
/// Stock writes one comma-separated element per hop, each element being that
/// hop's hash in hex, so `"a1b2,c3d4"` is two hops at width 2. That maps
/// directly onto our width-aware path model (#309): [hopCount] is our hash
/// count and [hashWidth] is our per-hop width. Neither is inferred.
class StockOutPath {
  StockOutPath({required this.hashWidth, required this.bytes})
    : assert(hashWidth > 0),
      assert(bytes.length % hashWidth == 0);

  /// The `""` form of the field, as distinct from the key being null.
  ///
  /// Both mean "no path" and the corpus contains 10 of these against 2448
  /// nulls, but stock writes both and we do not know what distinguishes them.
  /// Keeping them apart costs one constructor and makes an Offband re-export
  /// byte-identical to its source, so we keep them apart.
  StockOutPath.empty() : hashWidth = 0, bytes = _noBytes;

  static final Uint8List _noBytes = Uint8List(0);

  /// Bytes per hop hash, 1..3, or 0 for [StockOutPath.empty].
  /// See [kStockPathHashWidths].
  final int hashWidth;

  /// Flattened hop hashes, `hopCount * hashWidth` bytes.
  final Uint8List bytes;

  int get hopCount => hashWidth == 0 ? 0 : bytes.length ~/ hashWidth;

  /// Parses `out_path_list`. A null key returns null; `""` returns
  /// [StockOutPath.empty]. Both mean the contact has no route.
  static StockOutPath? fromJson(Object? value, String path) {
    if (value == null) return null;
    final text = _asString(value, path);
    if (text.isEmpty) return StockOutPath.empty();

    final elements = text.split(',');
    final widths = elements.map((e) => e.length).toSet();
    if (widths.length != 1) {
      throw StockConfigFormatException(
        'hop hashes must all be the same width, got $widths',
        path: path,
      );
    }
    final chars = widths.single;
    if (chars.isOdd || !kStockPathHashWidths.contains(chars ~/ 2)) {
      throw StockConfigFormatException(
        'unsupported hop hash width of $chars characters',
        path: path,
      );
    }

    final width = chars ~/ 2;
    final bytes = BytesBuilder();
    for (final element in elements) {
      bytes.add(_parseHex(element, path, expectBytes: width));
    }
    return StockOutPath(hashWidth: width, bytes: bytes.toBytes());
  }

  String toJson() {
    if (hashWidth == 0) return '';
    final hops = <String>[];
    for (var i = 0; i < bytes.length; i += hashWidth) {
      hops.add(pubKeyToHex(Uint8List.sublistView(bytes, i, i + hashWidth)));
    }
    return hops.join(',');
  }
}

/// One contact. This is a near 1:1 serialization of the firmware's
/// `ContactInfo` struct, with [customName] as the one app-side addition.
class StockContact {
  const StockContact({
    required this.type,
    required this.name,
    required this.publicKey,
    required this.flags,
    required this.latitude,
    required this.longitude,
    required this.lastAdvert,
    required this.lastModified,
    this.customName,
    this.outPath,
  });

  /// `ADV_TYPE_*`: 1 chat, 2 repeater, 3 room, 4 sensor.
  final int type;

  final String name;

  /// App-side rename. Null in all 2359 contacts of the reference corpus, so
  /// its round-trip behavior is carried but unverified (#569).
  final String? customName;

  final Uint8List publicKey;

  /// Bit 0 is "favourite" (firmware `flags & 0x01`).
  final int flags;

  final double latitude;
  final double longitude;

  /// Epoch seconds by THEIR clock. **Not sanitized**: the reference corpus
  /// ranges from 14 to the year 2095. Kept as a raw int so no caller mistakes
  /// it for a trustworthy time.
  final int lastAdvert;

  /// Epoch seconds by OUR clock. Same caveat as [lastAdvert].
  final int lastModified;

  final StockOutPath? outPath;

  bool get isFavourite => flags & 0x01 != 0;

  factory StockContact.fromJson(Map<String, dynamic> json, String path) {
    return StockContact(
      type: _asInt(json['type'], '$path.type'),
      name: _asString(json['name'], '$path.name'),
      customName: json['custom_name'] == null
          ? null
          : _asString(json['custom_name'], '$path.custom_name'),
      publicKey: _parseHex(
        _asString(json['public_key'], '$path.public_key'),
        '$path.public_key',
        expectBytes: _publicKeyBytes,
      ),
      flags: _asInt(json['flags'], '$path.flags'),
      latitude: _parseCoord(json['latitude'], '$path.latitude'),
      longitude: _parseCoord(json['longitude'], '$path.longitude'),
      lastAdvert: _asInt(json['last_advert'], '$path.last_advert'),
      lastModified: _asInt(json['last_modified'], '$path.last_modified'),
      outPath: StockOutPath.fromJson(
        json['out_path_list'],
        '$path.out_path_list',
      ),
    );
  }

  Map<String, dynamic> toJson() {
    if (name.length > kStockMaxContactNameChars) {
      throw StockConfigFormatException(
        'contact name is ${name.length} characters; stock firmware stores at '
        'most $kStockMaxContactNameChars and would truncate it',
        path: 'contacts[].name',
      );
    }
    return {
      'type': type,
      'name': name,
      'custom_name': customName,
      'public_key': pubKeyToHex(publicKey),
      'flags': flags,
      'latitude': _coordToJson(latitude),
      'longitude': _coordToJson(longitude),
      'last_advert': lastAdvert,
      'last_modified': lastModified,
      'out_path_list': outPath?.toJson(),
    };
  }
}

/// A whole stock config export.
///
/// Every section is nullable, and null means "the user did not select this
/// section", which is distinct from an empty list. Absent sections are omitted
/// from [toJson] entirely rather than written as null, matching stock.
class StockConfig {
  const StockConfig({
    this.name,
    this.publicKey,
    this.privateKey,
    this.radioSettings,
    this.positionSettings,
    this.otherSettings,
    this.autoAddSettings,
    this.channels,
    this.contacts,
  });

  final String? name;

  /// 32 bytes. Travels as a unit with [privateKey]: stock's identity control
  /// emits both or neither.
  final Uint8List? publicKey;

  /// 64 bytes. See [publicKey].
  final Uint8List? privateKey;

  final StockRadioSettings? radioSettings;
  final StockPositionSettings? positionSettings;
  final StockOtherSettings? otherSettings;
  final StockAutoAddSettings? autoAddSettings;

  /// Ordered; array position is the channel index.
  final List<StockChannel>? channels;

  final List<StockContact>? contacts;

  /// Parses a decoded JSON object.
  ///
  /// Unknown top-level keys are ignored, not rejected: the format has no
  /// version field, so tolerating additions is the only way to survive a stock
  /// release that adds one.
  factory StockConfig.fromJson(Map<String, dynamic> json) {
    final channelsJson = json['channels'];
    final contactsJson = json['contacts'];

    return StockConfig(
      name: json['name'] == null ? null : _asString(json['name'], 'name'),
      publicKey: json['public_key'] == null
          ? null
          : _parseHex(
              _asString(json['public_key'], 'public_key'),
              'public_key',
              expectBytes: _publicKeyBytes,
            ),
      privateKey: json['private_key'] == null
          ? null
          : _parseHex(
              _asString(json['private_key'], 'private_key'),
              'private_key',
              expectBytes: _privateKeyBytes,
            ),
      radioSettings: json['radio_settings'] == null
          ? null
          : StockRadioSettings.fromJson(
              _asObject(json['radio_settings'], 'radio_settings'),
              'radio_settings',
            ),
      positionSettings: json['position_settings'] == null
          ? null
          : StockPositionSettings.fromJson(
              _asObject(json['position_settings'], 'position_settings'),
              'position_settings',
            ),
      otherSettings: json['other_settings'] == null
          ? null
          : StockOtherSettings.fromJson(
              _asObject(json['other_settings'], 'other_settings'),
              'other_settings',
            ),
      autoAddSettings: json['auto_add_settings'] == null
          ? null
          : StockAutoAddSettings.fromJson(
              _asObject(json['auto_add_settings'], 'auto_add_settings'),
              'auto_add_settings',
            ),
      channels: channelsJson == null
          ? null
          : _parseList(
              channelsJson,
              'channels',
              (item, path) =>
                  StockChannel.fromJson(_asObject(item, path), path),
            ),
      contacts: contactsJson == null
          ? null
          : _parseList(
              contactsJson,
              'contacts',
              (item, path) =>
                  StockContact.fromJson(_asObject(item, path), path),
            ),
    );
  }

  static List<T> _parseList<T>(
    Object? value,
    String path,
    T Function(Object? item, String itemPath) parse,
  ) {
    if (value is! List) {
      throw StockConfigFormatException('expected an array', path: path);
    }
    final result = <T>[];
    for (var i = 0; i < value.length; i++) {
      result.add(parse(value[i], '$path[$i]'));
    }
    return result;
  }

  /// Parses raw file text.
  factory StockConfig.parse(String source) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException catch (e) {
      throw StockConfigFormatException('file is not valid JSON: ${e.message}');
    }
    return StockConfig.fromJson(_asObject(decoded, r'$'));
  }

  Map<String, dynamic> toJson() {
    return {
      if (name != null) 'name': name,
      if (publicKey != null) 'public_key': pubKeyToHex(publicKey!),
      if (privateKey != null) 'private_key': pubKeyToHex(privateKey!),
      if (radioSettings != null) 'radio_settings': radioSettings!.toJson(),
      if (positionSettings != null)
        'position_settings': positionSettings!.toJson(),
      if (otherSettings != null) 'other_settings': otherSettings!.toJson(),
      if (autoAddSettings != null)
        'auto_add_settings': autoAddSettings!.toJson(),
      if (channels != null) 'channels': [for (final c in channels!) c.toJson()],
      if (contacts != null) 'contacts': [for (final c in contacts!) c.toJson()],
    };
  }

  String encode() => jsonEncode(toJson());
}
