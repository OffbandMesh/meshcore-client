import 'dart:convert';
import 'dart:typed_data';

import '../models/contact.dart';
import '../utils/app_logger.dart';
import 'drift/blob_store.dart';
import 'prefs_manager.dart';

class ContactStore {
  static const String _keyPrefix = 'contacts';

  String publicKeyHex = '';
  set setPublicKeyHex(String value) =>
      publicKeyHex = value.length > 10 ? value.substring(0, 10) : '';

  String get keyFor => '$_keyPrefix$publicKeyHex';

  Future<List<Contact>> loadContacts() async {
    if (publicKeyHex.isEmpty) {
      appLogger.warn('Public key hex is not set. Cannot load contacts.');
      return [];
    }
    // Bulk data lives in drift (#335). The fallback covers a key the migration
    // has not moved yet, and logs loudly if it fires.
    final blobs = BlobStore.instance;
    String? jsonString = await blobs.readWithPrefsFallback(keyFor);

    if (jsonString == null || jsonString.isEmpty) {
      // Pre-device-scoping data still sits under the legacy unscoped key in
      // SharedPreferences. Only touch prefs when it actually exists: an
      // unconditional remove costs a full-file rewrite on Windows and a
      // 5 MiB-capped synchronous write on web (#306).
      final prefs = PrefsManager.instance;
      final legacy = prefs.get(_keyPrefix);
      if (legacy is String && legacy.isNotEmpty) {
        appLogger.info(
          'Migrating contacts from legacy key $_keyPrefix to $keyFor (drift)',
        );
        await blobs.write(keyFor, legacy);
        await prefs.remove(_keyPrefix);
        jsonString = legacy;
      }
    }
    if (jsonString == null || jsonString.isEmpty) {
      return [];
    }

    try {
      final jsonList = jsonDecode(jsonString) as List<dynamic>;
      return jsonList
          .map((entry) => _fromJson(entry as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveContacts(List<Contact> contacts) async {
    if (publicKeyHex.isEmpty) {
      appLogger.warn('Public key hex is not set. Cannot save contacts.');
      return;
    }
    final jsonList = contacts.map(_toJson).toList();
    await BlobStore.instance.write(keyFor, jsonEncode(jsonList));
  }

  Map<String, dynamic> _toJson(Contact contact) {
    return {
      'publicKey': base64Encode(contact.publicKey),
      'name': contact.name,
      'type': contact.type,
      'flags': contact.flags,
      'pathLength': contact.pathLength,
      'pathHashWidth': contact.pathHashWidth,
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
      'isActive': contact.isActive,
      'rawPacket': contact.rawPacket != null
          ? base64Encode(contact.rawPacket!)
          : null,
    };
  }

  Contact _fromJson(Map<String, dynamic> json) {
    final lastSeenMs = json['lastSeen'] as int? ?? 0;
    final lastMessageMs = json['lastMessageAt'] as int?;
    final lastModifiedMs = json['lastModified'] as int?;
    final isLegacyPathRecord =
        !json.containsKey('pathHashWidth') &&
        ((json['pathLength'] as int? ?? -1) > 0);
    if (isLegacyPathRecord) {
      appLogger.info(
        'Dropping pre-#309 path for contact ${json['name']} '
        '(decoded with the old count-as-bytes rule, so truncated); '
        'reverting to flood until the device re-supplies it',
      );
    }
    return Contact(
      publicKey: Uint8List.fromList(base64Decode(json['publicKey'] as String)),
      name: json['name'] as String? ?? 'Unknown',
      type: json['type'] as int? ?? 0,
      flags: json['flags'] as int? ?? 0,
      // Records written before #309 have no 'pathHashWidth' and their path was
      // decoded with the old count-as-bytes rule, so at any width above 1 the
      // stored bytes are a truncated fragment. Truncated bytes cannot be
      // recovered by reinterpreting them, so a legacy record's path is dropped
      // and the contact reverts to flood until the radio re-supplies it (the
      // device refreshes contacts routinely, so this self-heals). Ben's call:
      // re-fetch rather than keep a path we know is wrong. (#309)
      pathLength: isLegacyPathRecord ? -1 : (json['pathLength'] as int? ?? -1),
      pathHashWidth: json['pathHashWidth'] as int? ?? 1,
      path: (!isLegacyPathRecord && json['path'] != null)
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
      isActive: json['isActive'] as bool? ?? true,
      rawPacket: json['rawPacket'] != null
          ? Uint8List.fromList(base64Decode(json['rawPacket'] as String))
          : null,
    );
  }
}
