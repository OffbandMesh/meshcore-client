import '../models/config_profile.dart';

/// Enumerates the device writes a [ConfigProfile] implies (#405), device-agnostic
/// so observer / repeater / companion executors share the same rules:
///
/// - **Skip null or empty**, a profile only touches keys it actually sets; a
///   blank never clobbers a configured value. Clearing is a separate explicit op.
/// - **Skip `jwt_token`**, it's live-minted by firmware at connect, never config.
/// - **`enabled` is written last** (the executor's activation guard), so it is
///   returned separately from [BrokerWrites.fields].
/// - **Danger fields** (owner/identity/credentials) are flagged so the preview
///   (#406) can gate them: broker `username`/`password`/`jwt_owner`/`jwt_email`,
///   and global `wifi.pwd`.

/// Broker sub-keys whose set/change/wipe requires the preview's red danger gate.
const Set<String> kDangerBrokerFields = {
  ConfigKeys.brokerUsername,
  ConfigKeys.brokerPassword,
  ConfigKeys.brokerJwtOwner,
  ConfigKeys.brokerJwtEmail,
};

/// Global flat keys requiring the danger gate.
const Set<String> kDangerFlatKeys = {ConfigKeys.wifiPassword};

/// A single flat (non-broker) write: `wifi.*`, `mqtt.iata`, `mqtt.status_interval`.
class FlatWrite {
  const FlatWrite(this.key, this.value, {this.danger = false});
  final String key;
  final String value;
  final bool danger;
}

/// The writes for one broker slot. [fields] excludes `enabled` (written last by
/// the executor) and `jwt_token` (never written). [enabled] is null when the
/// profile doesn't set it, so the executor preserves the device's current state.
class BrokerWrites {
  const BrokerWrites({
    required this.slot,
    required this.fields,
    required this.enabled,
    required this.dangerFields,
  });
  final int slot;
  final Map<String, String> fields;
  final bool? enabled;
  final Set<String> dangerFields;
}

/// The full set of writes a profile implies.
class ProfileWrites {
  const ProfileWrites({required this.flats, required this.brokers});

  /// Global flats, already ordered so `wifi.enabled` (if present) comes last.
  final List<FlatWrite> flats;
  final List<BrokerWrites> brokers;

  bool get isEmpty => flats.isEmpty && brokers.isEmpty;

  /// True if any write (flat or broker) is a danger-gated field.
  bool get hasDanger =>
      flats.any((f) => f.danger) ||
      brokers.any((b) => b.dangerFields.isNotEmpty);
}

/// Partition writes into (safe, danger) so the preview's two buttons each apply
/// their own set: the normal Apply writes safe changes; the red gate writes the
/// credential/identity ones. A broker with both is split across both, its
/// `enabled` toggle rides with the safe half only.
({ProfileWrites safe, ProfileWrites danger}) splitProfileWrites(
  ProfileWrites w,
) {
  final safeFlats = w.flats.where((f) => !f.danger).toList();
  final dangerFlats = w.flats.where((f) => f.danger).toList();

  final safeBrokers = <BrokerWrites>[];
  final dangerBrokers = <BrokerWrites>[];
  for (final b in w.brokers) {
    final safeFields = <String, String>{
      for (final e in b.fields.entries)
        if (!b.dangerFields.contains(e.key)) e.key: e.value,
    };
    final dangerFields = <String, String>{
      for (final e in b.fields.entries)
        if (b.dangerFields.contains(e.key)) e.key: e.value,
    };
    if (safeFields.isNotEmpty || b.enabled != null) {
      safeBrokers.add(
        BrokerWrites(
          slot: b.slot,
          fields: safeFields,
          enabled: b.enabled,
          dangerFields: const {},
        ),
      );
    }
    if (dangerFields.isNotEmpty) {
      dangerBrokers.add(
        BrokerWrites(
          slot: b.slot,
          fields: dangerFields,
          enabled: null, // never toggle activation from the credential pass
          dangerFields: dangerFields.keys.toSet(),
        ),
      );
    }
  }

  return (
    safe: ProfileWrites(flats: safeFlats, brokers: safeBrokers),
    danger: ProfileWrites(flats: dangerFlats, brokers: dangerBrokers),
  );
}

bool _blank(String? v) => v == null || v.isEmpty;

ProfileWrites enumerateProfileWrites(ConfigProfile p) {
  final flats = <FlatWrite>[];

  // WiFi, ssid/pwd first, enabled last (activation guard).
  final wifi = p.wifi;
  if (wifi != null) {
    if (!_blank(wifi.ssid)) {
      flats.add(FlatWrite(ConfigKeys.wifiSsid, wifi.ssid!));
    }
    if (!_blank(wifi.password)) {
      flats.add(
        FlatWrite(ConfigKeys.wifiPassword, wifi.password!, danger: true),
      );
    }
    if (wifi.enabled != null) {
      flats.add(FlatWrite(ConfigKeys.wifiEnabled, wifi.enabled! ? '1' : '0'));
    }
  }

  if (!_blank(p.regionIata)) {
    flats.add(FlatWrite(ConfigKeys.mqttIata, p.regionIata!));
  }
  if (p.statusInterval != null) {
    flats.add(FlatWrite(ConfigKeys.mqttStatusInterval, '${p.statusInterval}'));
  }

  final brokers = <BrokerWrites>[];
  for (final b in p.brokers) {
    final fields = <String, String>{};
    void put(String key, String? value) {
      if (!_blank(value)) fields[key] = value!;
    }

    put(ConfigKeys.brokerUrl, b.url);
    if (b.port != null) fields[ConfigKeys.brokerPort] = '${b.port}';
    if (b.transport != null) {
      fields[ConfigKeys.brokerTransport] = b.transport!.wire;
    }
    if (b.authType != null) {
      fields[ConfigKeys.brokerAuthType] = b.authType!.wire;
    }
    put(ConfigKeys.brokerUsername, b.username);
    put(ConfigKeys.brokerPassword, b.password);
    // jwt_token deliberately omitted, live-minted at connect, never config.
    put(ConfigKeys.brokerJwtAudience, b.jwtAudience);
    if (b.jwtRefresh != null) {
      fields[ConfigKeys.brokerJwtRefresh] = '${b.jwtRefresh}';
    }
    put(ConfigKeys.brokerJwtOwner, b.jwtOwner);
    put(ConfigKeys.brokerJwtEmail, b.jwtEmail);
    put(ConfigKeys.brokerCaCert, b.caCert);
    put(ConfigKeys.brokerTopicPrefix, b.topicPrefix);
    put(ConfigKeys.brokerIataOverride, b.iataOverride);

    if (fields.isEmpty && b.enabled == null) continue; // nothing to write

    brokers.add(
      BrokerWrites(
        slot: b.slot,
        fields: fields,
        enabled: b.enabled,
        dangerFields: fields.keys.where(kDangerBrokerFields.contains).toSet(),
      ),
    );
  }

  return ProfileWrites(flats: flats, brokers: brokers);
}
