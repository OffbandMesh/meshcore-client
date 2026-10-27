import 'dart:convert';
import 'dart:typed_data';

import '../models/contact.dart';
import '../utils/app_logger.dart';
import 'drift/blob_store.dart';

class ContactDiscoveryStore {
  static const String _keyPrefix = 'discovered_contacts';

  /// First 10 hex of the connected radio's key, like every other per-radio
  /// store. Discovered contacts are what THIS radio heard, so they are scoped
  /// per radio and never shared across radios on the same host (#754). The
  /// legacy unscoped `discovered_contacts` blob is left orphaned; the list
  /// self-heals as each radio re-hears adverts.
  String publicKeyHex = '';
  set setPublicKeyHex(String value) =>
      publicKeyHex = value.length > 10 ? value.substring(0, 10) : '';

  String get _keyFor => '$_keyPrefix$publicKeyHex';

  Future<List<Contact>> loadContacts() async {
    // No connected radio -> no list (never the shared/legacy blob).
    if (publicKeyHex.isEmpty) return [];
    // Bulk data lives in drift (#335), not SharedPreferences. The fallback
    // covers a key the migration has not moved yet and logs loudly if it fires.
    final jsonStr = await BlobStore.instance.readWithPrefsFallback(_keyFor);
    if (jsonStr == null) return [];

    try {
      final jsonList = jsonDecode(jsonStr) as List<dynamic>;
      return jsonList
          .map((entry) => _fromJson(entry as Map<String, dynamic>))
          .toList();
    } catch (e) {
      // SAFELANE 6: a decode failure is not "no data".
      appLogger.error(
        'Failed to decode discovered contacts: $e',
        tag: 'Storage',
      );
      return [];
    }
  }

  Future<void> saveContacts(List<Contact> contacts) async {
    // No connected radio -> don't write an unscoped/shared blob.
    if (publicKeyHex.isEmpty) return;
    final jsonList = contacts.map(_toJson).toList();
    await BlobStore.instance.write(_keyFor, jsonEncode(jsonList));
  }

  Map<String, dynamic> _toJson(Contact contact) {
    return {
      'publicKey': base64Encode(contact.publicKey),
      // The RECEIVED name, never `contact.name`. Same one-way data loss as
      // `contact_store`: the getter would persist a user label into this key
      // and the next load would read it back as what the node calls itself.
      // (#750)
      'name': contact.receivedName,
      'type': contact.type,
      'flags': contact.flags,
      'pathLength': contact.pathLength,
      'path': base64Encode(contact.path),
      'pathOverride': contact.pathOverride,
      'pathOverrideBytes': contact.pathOverrideBytes != null
          ? base64Encode(contact.pathOverrideBytes!)
          : null,
      'latitude': contact.latitude,
      'longitude': contact.longitude,
      'lastSeen': contact.lastSeen.millisecondsSinceEpoch,
      'lastModified': contact.lastModified?.millisecondsSinceEpoch,
      'lastMessageAt': contact.lastMessageAt.millisecondsSinceEpoch,
      'rawPacket': contact.rawPacket != null
          ? base64Encode(contact.rawPacket!)
          : null,
    };
  }

  Contact _fromJson(Map<String, dynamic> json) {
    final lastSeenMs = json['lastSeen'] as int? ?? 0;
    final lastMessageMs = json['lastMessageAt'] as int?;
    final lastModifiedMs = json['lastModified'] as int?;
    return Contact(
      publicKey: Uint8List.fromList(base64Decode(json['publicKey'] as String)),
      // Fallback retained for the same reason as `contact_store`. (T31)
      receivedName: json['name'] as String? ?? 'Unknown',
      type: json['type'] as int? ?? 0,
      flags: json['flags'] as int? ?? 0,
      pathLength: json['pathLength'] as int? ?? -1,
      path: json['path'] != null
          ? Uint8List.fromList(base64Decode(json['path'] as String))
          : Uint8List(0),
      pathOverride: json['pathOverride'] as int?,
      pathOverrideBytes: json['pathOverrideBytes'] != null
          ? Uint8List.fromList(
              base64Decode(json['pathOverrideBytes'] as String),
            )
          : null,
      latitude: (json['latitude'] as num?)?.toDouble(),
      longitude: (json['longitude'] as num?)?.toDouble(),
      lastSeen: DateTime.fromMillisecondsSinceEpoch(lastSeenMs),
      lastModified: lastModifiedMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(lastModifiedMs),
      lastMessageAt: DateTime.fromMillisecondsSinceEpoch(
        lastMessageMs ?? lastSeenMs,
      ),
      isActive: false,
      rawPacket: json['rawPacket'] != null
          ? Uint8List.fromList(base64Decode(json['rawPacket'] as String))
          : null,
    );
  }
}
