import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Region transport-key derivation, matching the MeshCore firmware
/// (`RegionMap.getTransportKeysFor` -> `TransportKeyStore.getAutoKeyFor`).
///
/// A public "hashtag" region's transport key is the first 16 bytes of
/// `SHA256` of the region name carrying exactly one leading `#`: auto-hashtag
/// names are hashed as stored, bare names get a `#` prepended. `$`-prefixed
/// regions are private, their keys live in a hardware keystore and are not
/// derivable from the name. Names discovered over the air arrive `#`-stripped,
/// so the client re-adds the `#` here.
const int _keyLength = 16;

/// True for a private (`$`-prefixed) region, whose key is not name-derivable.
bool isPrivateRegionName(String name) => name.trim().startsWith(r'$');

/// The region name as the firmware hashes it: exactly one leading `#`.
String normalizeHashtag(String name) {
  final stripped = name.trim().replaceFirst(RegExp(r'^#+'), '');
  return '#$stripped';
}

/// First 16 bytes of `SHA256("#"+name)`.
///
/// Returns null when [name] is blank or a private (`$`) region.
Uint8List? transportKeyForName(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty || isPrivateRegionName(trimmed)) return null;
  final digest = sha256.convert(utf8.encode(normalizeHashtag(trimmed))).bytes;
  return Uint8List.fromList(digest.sublist(0, _keyLength));
}

/// The 2-byte on-air transport code the firmware stamps on a scoped packet:
/// `HMAC-SHA256(key, payloadType || payload)`, first two bytes read as a
/// little-endian `uint16` (firmware `TransportKey::calcTransportCode`).
int onAirCode(Uint8List key, int payloadType, Uint8List payload) {
  final mac = Hmac(sha256, key).convert(<int>[payloadType, ...payload]).bytes;
  return reserveTransportCode(mac[0] | (mac[1] << 8));
}

/// Firmware reserves `0x0000` and `0xFFFF`, bumping each by one.
int reserveTransportCode(int code) {
  if (code == 0x0000) return 0x0001;
  if (code == 0xFFFF) return 0xFFFE;
  return code;
}
