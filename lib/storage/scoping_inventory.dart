/// The declared scoping verdict for every persistence surface (#853, #936).
///
/// Feature #853's acceptance bar is that "every store has a verified scoping
/// verdict (per-radio or deliberately-global) and no hole remains". Until this
/// file existed, the only way to check that was for a human to re-read an audit
/// in an issue body, which is how #754 and #856 survived three earlier bleed
/// fixes. This file is that audit, in code, with a test that fails when a new
/// candidate key appears undeclared.
///
/// **Adding a storage key means adding a row here.** The test in
/// `test/storage/scoping_inventory_test.dart` scans `lib/` for the shape every
/// key in this repo uses, a `const String` whose value is lower snake_case, and
/// fails if one is not classified below. A key that is not a storage key goes
/// in [nonStorageConstants] with a reason, so "it isn't a key" is a written
/// claim rather than a silence.
library;

enum ScopingVerdict {
  /// Scoped by the first 10 hex of the connected radio's public key, the
  /// scheme every per-radio store in this repo uses. Radio A's data is never
  /// visible while radio B is connected.
  perRadio,

  /// Global, and that is correct. The reason is mandatory: without it a later
  /// audit re-opens the surface as a hole, which is exactly the churn #853
  /// exists to end.
  globalOnPurpose,

  /// Global, and that is a defect. Each of these has an open issue. The test
  /// asserts the set matches the known holes, so a NEW hole cannot hide among
  /// them and a FIXED one cannot be left mislabelled.
  knownHole,
}

class StorageSurface {
  const StorageSurface(
    this.key, {
    required this.verdict,
    required this.reason,
    required this.owner,
    this.issue,
  });

  /// The key or key prefix exactly as the source declares it.
  final String key;

  final ScopingVerdict verdict;

  /// Why this verdict. For [ScopingVerdict.perRadio], where the scoping comes
  /// from. For [ScopingVerdict.globalOnPurpose], why radio scoping would be
  /// wrong. For [ScopingVerdict.knownHole], what bleeds.
  final String reason;

  /// The file that owns the key, so a reader can go check.
  final String owner;

  /// Required for [ScopingVerdict.knownHole], so every hole is tracked.
  final int? issue;
}

/// Every persistence surface in the client, with its verdict.
const List<StorageSurface> storageSurfaces = [
  // ---------------------------------------------------------------------------
  // Per-radio. Each is fed the device-key prefix on connect.
  // ---------------------------------------------------------------------------
  StorageSurface(
    'channel_messages_',
    verdict: ScopingVerdict.perRadio,
    reason:
        'prefix + device key, then PSK identity within the radio (#194), '
        'so history survives a channel rename and does not follow a reused '
        'slot. The cross-radio bleed was #472',
    owner: 'lib/storage/channel_message_store.dart',
  ),
  StorageSurface(
    'messages_',
    verdict: ScopingVerdict.perRadio,
    reason: 'prefix + device key + contact key',
    owner: 'lib/storage/message_store.dart',
  ),
  StorageSurface(
    'channels',
    verdict: ScopingVerdict.perRadio,
    reason: 'prefix + device key',
    owner: 'lib/storage/channel_store.dart',
  ),
  StorageSurface(
    'channel_order_',
    verdict: ScopingVerdict.perRadio,
    reason:
        'prefix + device key; display order is per radio because the '
        'channel list is',
    owner: 'lib/storage/channel_order_store.dart',
  ),
  StorageSurface(
    'channel_region_scope_',
    verdict: ScopingVerdict.perRadio,
    reason: 'prefix + device key',
    owner: 'lib/storage/channel_region_scope_store.dart',
  ),
  StorageSurface(
    'contacts',
    verdict: ScopingVerdict.perRadio,
    reason:
        'prefix + device key; a contact list belongs to the radio that '
        'holds it',
    owner: 'lib/storage/contact_store.dart',
  ),
  StorageSurface(
    'contact_groups',
    verdict: ScopingVerdict.perRadio,
    reason: 'prefix + device key; groups reference that radio\'s contacts',
    owner: 'lib/storage/contact_group_store.dart',
  ),
  StorageSurface(
    'contact_unread_count',
    verdict: ScopingVerdict.perRadio,
    reason: 'prefix + device key; unread counts follow the message history',
    owner: 'lib/storage/unread_store.dart',
  ),
  StorageSurface(
    'discovered_contacts',
    verdict: ScopingVerdict.perRadio,
    reason:
        'prefix + device key since #754. A discovered node is what THIS '
        'radio heard. An unset key loads nothing and never writes, so it '
        'cannot touch the orphaned legacy blob',
    owner: 'lib/storage/contact_discovery_store.dart',
  ),
  StorageSurface(
    'communities_v1',
    verdict: ScopingVerdict.perRadio,
    reason: 'prefix + device key',
    owner: 'lib/storage/community_store.dart',
  ),
  StorageSurface(
    'channel_cyr2lat_',
    verdict: ScopingVerdict.perRadio,
    reason:
        'prefix + device key + channel index, via keyForCyr2Lat. NOT '
        'previously audited: #853\'s audit listed channel_settings_store as '
        'one surface, but it owns two keys and this inventory found the '
        'second',
    owner: 'lib/storage/channel_settings_store.dart',
  ),
  StorageSurface(
    'contact_cyr2lat_',
    verdict: ScopingVerdict.perRadio,
    reason:
        'prefix + device key + contact key. NOT previously audited, same '
        'reason as channel_cyr2lat_',
    owner: 'lib/storage/contact_settings_store.dart',
  ),
  StorageSurface(
    'block_keys_v1',
    verdict: ScopingVerdict.perRadio,
    reason:
        'prefix + device key. A blank radio is no longer offloaded the '
        'client list (#471)',
    owner: 'lib/storage/block_store.dart',
  ),
  StorageSurface(
    'block_names_v1',
    verdict: ScopingVerdict.perRadio,
    reason: 'prefix + device key, alongside block_keys_v1',
    owner: 'lib/storage/block_store.dart',
  ),

  // ---------------------------------------------------------------------------
  // Known holes. Each has an issue and each is fixed in Epic B (#937).
  // ---------------------------------------------------------------------------
  StorageSurface(
    'path_history_',
    verdict: ScopingVerdict.knownHole,
    issue: 854,
    reason:
        'keyed by contact public key only, with no radio in the key, so a '
        'learned mesh route bleeds between any two radios that share a '
        'contact. Also unbounded at 2,041 keys and 86% of the prefs file '
        '(#924), while PathHistoryService caches only 50',
    owner: 'lib/services/storage_service.dart',
  ),
  StorageSurface(
    'delivery_observations',
    verdict: ScopingVerdict.knownHole,
    issue: 856,
    reason:
        'one global list feeding the ACK-timeout ML model, so one radio\'s '
        'RF timing trains another radio\'s predictions. Silent accuracy loss, '
        'which is why it was never reported',
    owner: 'lib/services/storage_service.dart',
  ),
  // `pending_messages` (#855) was listed here and is GONE, not reclassified.
  // It had no callers anywhere in lib/ or test/ and the key was absent from
  // the owner's live prefs, so the fix was deletion rather than scoping. The
  // inventory's "declared but vanished from source" check is what keeps that
  // honest in the other direction: if the key ever comes back, the gate fails
  // until somebody declares it and says why.

  // ---------------------------------------------------------------------------
  // Global on purpose. The reason is the point: it stops a later audit
  // re-opening these as holes.
  // ---------------------------------------------------------------------------
  StorageSurface(
    'client_install_id',
    verdict: ScopingVerdict.globalOnPurpose,
    reason:
        'the identity of this app INSTALL, not of any radio. Scoping it '
        'per radio would mint a new install id per radio, which is the '
        'opposite of what it is for',
    owner: 'lib/storage/client_id_store.dart',
  ),
  StorageSurface(
    'app_settings',
    verdict: ScopingVerdict.globalOnPurpose,
    reason:
        'app-wide UX: theme, language, units, map and notification '
        'preferences. The per-radio data it does carry is scoped INSIDE it, by '
        'channelNotifyModesByRadio: device key -> channel PSK -> mode (#839). '
        'So the blob is global and the radio-specific part within it is not',
    owner: 'lib/models/app_settings.dart',
  ),
  StorageSurface(
    'repeater_passwords',
    verdict: ScopingVerdict.globalOnPurpose,
    reason:
        'keyed by the repeater NODE, not by the radio connecting to it. '
        'The same repeater has the same password whichever radio reaches it, '
        'so per-radio scoping would make the user re-enter it per radio',
    owner: 'lib/services/storage_service.dart',
  ),
  StorageSurface(
    'repeater_auto_clock_sync_after_login',
    verdict: ScopingVerdict.globalOnPurpose,
    reason: 'keyed by repeater node, same reasoning as repeater_passwords',
    owner: 'lib/services/storage_service.dart',
  ),
  StorageSurface(
    'map_removed_marker_ids',
    verdict: ScopingVerdict.globalOnPurpose,
    reason:
        'a set of node ids the user dismissed from the map. "Do not show '
        'me this node" is a statement about the NODE, like repeater_passwords, '
        'not about the radio that happened to hear it. NOT previously audited: '
        'surfaced by this inventory, see #936',
    owner: 'lib/services/map_marker_service.dart',
  ),
  StorageSurface(
    'map_tile_cache',
    verdict: ScopingVerdict.globalOnPurpose,
    reason:
        'cached OSM tiles. Geography does not depend on which radio is '
        'connected, and per-radio caching would multiply the download',
    owner: 'lib/services/map_tile_cache_service.dart',
  ),
  StorageSurface(
    'radio_presets_v1_',
    verdict: ScopingVerdict.globalOnPurpose,
    reason:
        'prefix + preset FILE name. A cached catalogue of region presets '
        'fetched from assets or upstream, not state belonging to a radio. NOT '
        'previously audited: surfaced by this inventory',
    owner: 'lib/services/radio_preset_service.dart',
  ),
  StorageSurface(
    'anr_last_exit_ts_ms',
    verdict: ScopingVerdict.globalOnPurpose,
    reason:
        'watermark for which ApplicationExitInfo records have been '
        'processed (#906). A property of the app process, not of a radio. NOT '
        'previously audited: surfaced by this inventory',
    owner: 'lib/services/app_exit_info_service.dart',
  ),
  StorageSurface(
    '__msgrows_migrated',
    verdict: ScopingVerdict.globalOnPurpose,
    reason:
        'the set of store keys whose blob has been moved into message rows '
        '(#920). Global because the keys it lists are themselves already '
        'radio-scoped, so scoping the marker would scope it twice',
    owner: 'lib/storage/drift/blob_store.dart',
  ),
];

/// Constants that match the key shape but are not persistence keys.
///
/// This list exists so "that is not a storage key" has to be written down and
/// justified, instead of a new key slipping through because nobody looked.
const Map<String, String> nonStorageConstants = {
  'offband_store': 'the drift database FILE name, not a key within it',
  '__all__':
      'the sentinel value for "all groups" in the contacts filter '
      '(UiViewStateService). A filter VALUE, not a key, and not persisted '
      'under this name',
  '__reaction_send__':
      'a prefix for an in-memory send-queue id in the '
      'connector, distinguishing a reaction send from a message send. Never '
      'reaches storage',
  'psk_':
      'a marker inside a channel-history key, distinguishing a PSK '
      'identity from a legacy slot index (#194). Not a key by itself',
  'anr':
      'a log tag / exit-reason discriminator in the ANR capture path, not '
      'persisted under this name',
  'los_error_select_start_end':
      'an in-memory error sentinel in the line-of-sight screen, assigned to '
      '_error and compared against. Never written to storage',
  'los_error_invalid_input': 'the same, for invalid input',
  'los_error_elevation_unavailable':
      'the same, raised by the line-of-sight service when elevation data is '
      'missing. Never written to storage',
  // MQTT broker config field names. These are keys within a config map that is
  // itself persisted under another surface, not top-level storage keys.
  'auth_type': 'MQTT broker config field name',
  'ca_cert': 'MQTT broker config field name',
  'enabled': 'MQTT broker config field name',
  'password': 'MQTT broker config field name',
  'port': 'MQTT broker config field name',
  'topic_prefix': 'MQTT broker config field name',
  'transport': 'MQTT broker config field name',
  'url': 'MQTT broker config field name',
  'username': 'MQTT broker config field name',
  'jwt_aud': 'JWT claim name in a broker auth payload',
  'jwt_email': 'JWT claim name',
  'jwt_owner': 'JWT claim name',
  'jwt_refresh': 'JWT claim name',
  'jwt_token': 'JWT claim name',
  'iata_override': 'a field name within a config payload, not a storage key',
};
