import 'dart:typed_data';
import 'package:meshcore_open/utils/app_logger.dart';

import '../connector/meshcore_protocol.dart';

class Contact {
  final Uint8List publicKey;
  final String name;
  final int type;
  final int flags;

  /// Hop count for [path]: -1 = flood, 0+ = number of hops.
  ///
  /// This is the firmware path-len field's low 6 bits, which firmware defines
  /// as a hash COUNT, not a byte length (`src/Packet.h:79-84`). It was
  /// previously treated as a byte count, which truncated every path at widths
  /// above 1. (#309)
  final int pathLength;

  /// Bytes per hop hash in [path] (1..3), from the path-len byte's high 2 bits.
  ///
  /// Carried per-path rather than read from the connector's global width, so a
  /// stored path can never be re-sliced at a width it was not captured at.
  final int pathHashWidth;

  final Uint8List path; // Path bytes from device (pathLength * pathHashWidth)
  final int?
  pathOverride; // User's path override: -1 = force flood, null = auto
  final Uint8List? pathOverrideBytes; // User's path override bytes
  final double? latitude;
  final double? longitude;
  final DateTime lastSeen;
  final DateTime lastMessageAt;
  final DateTime? lastModified;
  final bool isActive;
  final bool wasPulled;
  final Uint8List? rawPacket;

  Contact({
    required this.publicKey,
    required this.name,
    required this.type,
    this.flags = 0,
    required this.pathLength,
    this.pathHashWidth = 1,
    required this.path,
    this.pathOverride,
    this.pathOverrideBytes,
    this.latitude,
    this.longitude,
    required this.lastSeen,
    this.lastModified,
    DateTime? lastMessageAt,
    this.isActive = true,
    this.wasPulled = false,
    this.rawPacket,
  }) : lastMessageAt = lastMessageAt ?? lastSeen;

  String get publicKeyHex => pubKeyToHex(publicKey);

  /// Non-localized type label, intended for logs and non-UI exports
  /// (e.g. GPX). For UI use the `typeLabel(l10n)` extension in
  /// `lib/l10n/contact_localization.dart`.
  String get typeLabelRaw {
    switch (type) {
      case advTypeChat:
        return 'Chat';
      case advTypeRepeater:
        return 'Repeater';
      case advTypeRoom:
        return 'Room';
      case advTypeSensor:
        return 'Sensor';
      default:
        return 'Unknown';
    }
  }

  bool get hasLocation {
    const double epsilon = 1e-6;
    final lat = latitude ?? 0.0;
    final lon = longitude ?? 0.0;
    return (lat.abs() > epsilon || lon.abs() > epsilon) &&
        lat >= -90.0 &&
        lat <= 90.0 &&
        lon >= -180.0 &&
        lon <= 180.0;
  }

  bool get isFavorite => (flags & contactFlagFavorite) != 0;

  Contact copyWith({
    Uint8List? publicKey,
    String? name,
    int? type,
    int? flags,
    int? pathLength,
    int? pathHashWidth,
    Uint8List? path,
    int? pathOverride,
    Uint8List? pathOverrideBytes,
    bool clearPathOverride = false,
    double? latitude,
    double? longitude,
    DateTime? lastSeen,
    DateTime? lastMessageAt,
    DateTime? lastModified,
    bool? isActive,
    Uint8List? rawPacket,
  }) {
    return Contact(
      publicKey: publicKey ?? this.publicKey,
      name: name ?? this.name,
      type: type ?? this.type,
      flags: flags ?? this.flags,
      pathLength: pathLength ?? this.pathLength,
      pathHashWidth: pathHashWidth ?? this.pathHashWidth,
      path: path ?? this.path,
      pathOverride: clearPathOverride
          ? null
          : (pathOverride ?? this.pathOverride),
      pathOverrideBytes: clearPathOverride
          ? null
          : (pathOverrideBytes ?? this.pathOverrideBytes),
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      lastSeen: lastSeen ?? this.lastSeen,
      lastMessageAt: lastMessageAt ?? this.lastMessageAt,
      lastModified: lastModified ?? this.lastModified,
      isActive: isActive ?? this.isActive,
      rawPacket: rawPacket ?? this.rawPacket,
    );
  }

  /// Formats path bytes into comma-separated hex groups of [hashByteWidth] bytes.
  String pathFormattedIdList(int hashByteWidth) {
    final pathBytes = pathBytesForDisplay;
    if (pathBytes.isEmpty) return '';
    final w = hashByteWidth.clamp(1, 8);
    final parts = <String>[];
    for (int i = 0; i < pathBytes.length; i += w) {
      final end = (i + w) <= pathBytes.length ? (i + w) : pathBytes.length;
      final chunk = pathBytes.sublist(i, end);
      parts.add(
        chunk
            .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
            .join(),
      );
    }
    return parts.join(',');
  }

  /// Groups by this path's own captured width, not a global or legacy default.
  String get pathIdList => pathFormattedIdList(pathHashWidth);

  String get shortPubKeyHex {
    return "<${publicKeyHex.substring(0, 8)}...${publicKeyHex.substring(publicKeyHex.length - 8)}>";
  }

  Uint8List get pathBytesForDisplay {
    if (pathOverride != null) {
      if (pathOverride! < 0) return Uint8List(0);
      return pathOverrideBytes ?? Uint8List(0);
    }
    return path;
  }

  static Contact? fromFrame(Uint8List data) {
    if (data.isEmpty) return null;
    final reader = BufferReader(data);
    try {
      final respCode = reader.readByte();
      if (respCode != respCodeContact && respCode != pushCodeNewAdvert) {
        return null;
      }
      final pubKey = reader.readBytes(pubKeySize);

      // Guard: reject contacts with zeroed or mostly-zeroed public keys
      // (indicates corrupt flash storage on the firmware side)
      final zeroCount = pubKey.where((b) => b == 0).length;
      if (zeroCount > pubKeySize ~/ 2) return null;

      final type = reader.readByte();
      final flags = reader.readByte();
      final pathLen = reader.readByte();
      // The firmware path-len byte packs hash size in the high 2 bits and hash
      // COUNT (hops) in the low 6; the byte length is count * size
      // (`src/Packet.h:79-84`). 0xFF stays the flood sentinel.
      //
      // This previously read `count` BYTES, so at 2-byte width it kept half of
      // every path and discarded the rest, the truncation behind #240's failed
      // repeater logins. The width is taken from the path itself rather than the
      // connector's global width, so a path is always sliced at the width it was
      // captured at. (#309)
      final isFlood = pathLen == 0xFF;
      final hopCount = isFlood ? -1 : pathHopCount(pathLen);
      final hashWidth = isFlood ? 1 : pathHashSizeBytes(pathLen);
      final byteLen = isFlood ? 0 : (hopCount * hashWidth);
      final safePathLen = byteLen.clamp(0, maxPathSize);
      final pathBytes = reader.readBytes(maxPathSize).sublist(0, safePathLen);
      final name = reader.readCStringGreedy(maxNameSize);

      // Guard: reject contacts with non-printable names (corrupt flash data)
      if (name.isNotEmpty &&
          name.codeUnits.every((c) => c < 0x20 || c == 0xFFFD)) {
        return null;
      }

      // mandatory last_advert_timestamp
      final lastAdvertTimestamp = reader.readUInt32LE();

      double? lat, lon;
      DateTime? lastModified;
      if (reader.remaining >= 12) {
        final latRaw = reader.readInt32LE();
        final lonRaw = reader.readInt32LE();
        final lastModRaw = reader.readUInt32LE();
        // TODO: should this be &&?
        if (latRaw != 0 || lonRaw != 0) {
          lat = latRaw / 1e6;
          lon = lonRaw / 1e6;
        }
        if (lastModRaw != 0) {
          lastModified = DateTime.fromMillisecondsSinceEpoch(lastModRaw * 1000);
        }
      } else if (reader.remaining >= 8) {
        // Old layout: gps without lastmod
        final latRaw = reader.readInt32LE();
        final lonRaw = reader.readInt32LE();
        if (latRaw != 0 || lonRaw != 0) {
          lat = latRaw / 1e6;
          lon = lonRaw / 1e6;
        }
        appLogger.info(
          'Contact ${pubKeyToHex(pubKey).substring(0, 8)} has gps but no lastmod (legacy firmware layout)',
        );
      }

      return Contact(
        publicKey: pubKey,
        name: name.isEmpty ? 'Unknown' : name,
        type: type,
        flags: flags,
        pathLength:
            hopCount, // hop count from the low 6 bits; -1 = flood (#309)
        pathHashWidth: hashWidth, // bytes/hop from the high 2 bits (#309)
        path: pathBytes,
        latitude: lat,
        longitude: lon,
        lastSeen: DateTime.fromMillisecondsSinceEpoch(
          lastAdvertTimestamp * 1000,
        ),
        lastModified: lastModified,
        isActive: true,
        rawPacket: null,
      );
    } catch (e) {
      appLogger.error('Failed to parse contact frame: $e');
      return null;
    }
  }

  /// True once this contact has been confirmed on air by a signed advert.
  ///
  /// [lastSeen] maps to the firmware `last_advert_timestamp`, which a contact
  /// created from a bare key deliberately carries as the epoch so the advert
  /// replay guard cannot mute it (#627). That same sentinel doubles as the
  /// verification signal, for free, and it clears itself the moment a genuine
  /// advert arrives and the radio rewrites the field. (#630)
  bool get isAdvertVerified => lastSeen.millisecondsSinceEpoch != 0;

  /// Reference-app contact share URI for this contact, the inverse of
  /// [fromShareUri]. This is what the stock app accepts, so emitting it is
  /// what makes Offband cards and QRs importable by non-Offband users. (#626)
  ///
  /// Note this shares only the identity. It carries no path and no advert, so
  /// the receiving side gets an unverified stub exactly as we do.
  String toShareUri() =>
      buildShareUri(publicKeyHex: publicKeyHex, name: name, type: type);

  /// Builds the reference-app contact share URI from raw parts.
  ///
  /// Separate from [toShareUri] so the local device can share its OWN identity,
  /// which is a public key and a node name rather than a [Contact]. (#626)
  ///
  /// Spaces are percent-encoded rather than emitted as `+`. Both decode to a
  /// space, and this matches [Channel.toShareUri], which is already documented
  /// as round-tripping with the reference app's QR. (#161)
  static String buildShareUri({
    required String publicKeyHex,
    required String name,
    int type = advTypeChat,
  }) =>
      'meshcore://contact/add'
      '?name=${Uri.encodeComponent(name)}'
      '&public_key=$publicKeyHex'
      '&type=$type';

  /// Compact contact share for a CHANNEL message, `<key:type:name>`. (#611)
  ///
  /// This is a second, different format from [toShareUri], and deliberately so.
  /// It is what real clients put on the air, observed live in `#test` and
  /// `#hamradio`, and it is far cheaper: about 75 bytes against 117 for the
  /// equivalent URI. Channel text shares a 160-byte payload with the
  /// `Sender: ` prefix, so that difference is airtime, not neatness.
  ///
  /// Use the URI form for a QR, a DM, or an out-of-band paste. Use this for a
  /// channel.
  String toChannelShare() =>
      buildChannelShare(publicKeyHex: publicKeyHex, name: name, type: type);

  /// Builds the compact channel share from raw parts, so this device can share
  /// its OWN identity without constructing a [Contact]. (#611)
  ///
  /// Angle brackets are the delimiters, so any in [name] are dropped: a name
  /// carrying one would truncate the payload for every parser reading it. A
  /// colon is left alone, because the name is the final field and a correct
  /// parser splits on the first two colons only.
  static String buildChannelShare({
    required String publicKeyHex,
    required String name,
    int type = advTypeChat,
  }) {
    final safeName = name.replaceAll('<', '').replaceAll('>', '');
    return '<$publicKeyHex:$type:$safeName>';
  }

  /// Parses the compact channel share `<key:type:name>`, or null. (#611)
  ///
  /// The counterpart to [toChannelShare]. Without this the app would emit a
  /// format it could not itself accept, and a user copying a card out of a
  /// channel and pasting it into the add dialog would be rejected.
  ///
  /// Splits on the FIRST TWO colons only. The name is the final field and may
  /// contain colons, spaces, emoji and CJK, so splitting on the last colon or
  /// on every colon corrupts real names.
  ///
  /// Rendering a received card as a tappable Add Contact affordance is #610 and
  /// is separate; this only handles text pasted or scanned into the add flow.
  static Contact? fromChannelShare(String text) {
    final trimmed = text.trim();
    // Tolerate a card embedded in a longer message, which is how it arrives.
    final start = trimmed.indexOf('<');
    final end = trimmed.lastIndexOf('>');
    if (start < 0 || end <= start) return null;
    final body = trimmed.substring(start + 1, end);

    final firstColon = body.indexOf(':');
    if (firstColon < 0) return null;
    final secondColon = body.indexOf(':', firstColon + 1);
    if (secondColon < 0) return null;

    final keyHex = body.substring(0, firstColon).toLowerCase();
    if (keyHex.length != pubKeySize * 2) return null;
    final Uint8List publicKey;
    try {
      publicKey = hex2Uint8List(keyHex);
    } on FormatException {
      return null;
    }

    final type = int.tryParse(body.substring(firstColon + 1, secondColon));
    if (type == null || type < advTypeChat || type > advTypeSensor) return null;

    final name = body.substring(secondColon + 1);

    return Contact(
      publicKey: publicKey,
      name: name.isEmpty ? 'Unknown' : name,
      type: type,
      flags: 0,
      pathLength: -1,
      path: Uint8List(0),
      // Same unverified stub as the URI path, and for the same reason: the
      // epoch keeps the firmware advert replay guard from muting it. (#620)
      lastSeen: DateTime.fromMillisecondsSinceEpoch(0),
      rawPacket: null,
    );
  }

  /// Parses a contact from the reference-app share URI, or null if malformed.
  ///
  /// `meshcore://contact/add?name=<url-encoded>&public_key=<64 hex>&type=<1-4>`
  ///
  /// Spec: MeshCore firmware `docs/qr_codes.md`, the format the stock mobile
  /// app emits for both its contact QR and its share link. The payload is a
  /// BARE public key, not a signed advert, so the result is an identity stub:
  /// no path, no position, nothing the mesh has confirmed. A QR is this same
  /// URI rendered visually, so scanning shares this parser. (#625)
  ///
  /// Returns null for the fork's older `meshcore://<raw advert hex>` form,
  /// whose host is the leading hex rather than `contact`. Callers keep handling
  /// that separately: it carries a full signed advert and is strictly richer.
  static Contact? fromShareUri(String uri) {
    final parsed = Uri.tryParse(uri.trim());
    if (parsed == null || parsed.scheme != 'meshcore') return null;
    if (parsed.host != 'contact') return null;
    if (parsed.path.replaceAll('/', '') != 'add') return null;

    final keyHex = parsed.queryParameters['public_key'];
    if (keyHex == null || keyHex.length != pubKeySize * 2) return null;

    final Uint8List publicKey;
    try {
      publicKey = hex2Uint8List(keyHex);
    } on FormatException {
      return null;
    }

    // `type` is optional; stock always emits it, but a key alone is still a
    // usable identity. Out-of-range values are rejected rather than clamped:
    // in a three-parameter URI an impossible type signals corruption, and
    // silently mis-typing a contact is a user-visible defect. Widen this
    // deliberately if the spec ever adds a type.
    final typeRaw = parsed.queryParameters['type'];
    int type = advTypeChat;
    if (typeRaw != null && typeRaw.isNotEmpty) {
      final parsedType = int.tryParse(typeRaw);
      if (parsedType == null ||
          parsedType < advTypeChat ||
          parsedType > advTypeSensor) {
        return null;
      }
      type = parsedType;
    }

    final name = parsed.queryParameters['name'];

    return Contact(
      publicKey: publicKey,
      // Matches fromFrame's convention for a nameless contact.
      name: (name == null || name.isEmpty) ? 'Unknown' : name,
      type: type,
      flags: 0,
      // Flood until the mesh teaches us a path. Mirrors the firmware's
      // OUT_PATH_UNKNOWN for a contact that has never been routed to.
      pathLength: -1,
      path: Uint8List(0),
      // Deliberately the epoch, NOT DateTime.now().
      //
      // This maps to the firmware's `last_advert_timestamp`, which the advert
      // handler compares with `timestamp <= last_advert_timestamp` and treats
      // a non-greater value as a replay attack (`BaseChatMesh.cpp:142-145`).
      // Stamping "now" would leave this contact permanently deaf to its own
      // adverts, because advert timestamps come from the SENDER's clock and
      // clocks in the field run years behind. Zero lets any genuine advert win
      // and upgrade the stub in place. (#620)
      lastSeen: DateTime.fromMillisecondsSinceEpoch(0),
      // No advert packet, so this contact cannot be re-shared until one
      // arrives. The share path already gates on rawPacket.
      rawPacket: null,
    );
  }

  /// True if [uri] is a valid reference-app contact share URI. (#625)
  static bool isValidShareUri(String uri) => fromShareUri(uri) != null;

  @override
  bool operator ==(Object other) =>
      other is Contact && publicKeyHex == other.publicKeyHex;

  @override
  int get hashCode => publicKeyHex.hashCode;
  bool get teleBaseEnabled => (flags & contactFlagTeleBase) != 0;
  bool get teleLocEnabled => (flags & contactFlagTeleLoc) != 0;
  bool get teleEnvEnabled => (flags & contactFlagTeleEnv) != 0;
}
