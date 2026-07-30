import '../models/config_profile.dart';

/// Enumerates the device writes a [ConfigProfile] implies (#405), device-agnostic
/// so observer / repeater / companion executors share the same rules:
///
/// - **Skip null or empty**, a profile only touches keys it actually sets; a
///   blank never clobbers a configured value. Clearing is a separate explicit op.
/// - **Skip `jwt_token`**, it's live-minted by firmware at connect, never config.
/// - **Skip broker `enabled`** (#456), enabling a broker is the operator's
///   runtime decision, not profile config; apply preserves the current state.
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

/// The writes for one broker slot. [fields] excludes `jwt_token` (never written)
/// and the broker `enabled` flag (#456: not a profile field — apply preserves
/// the device's current enabled state).
class BrokerWrites {
  const BrokerWrites({
    required this.slot,
    required this.fields,
    required this.dangerFields,
  });
  final int slot;
  final Map<String, String> fields;
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
/// credential/identity ones. A broker with both is split across both.
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
    if (safeFields.isNotEmpty) {
      safeBrokers.add(
        BrokerWrites(slot: b.slot, fields: safeFields, dangerFields: const {}),
      );
    }
    if (dangerFields.isNotEmpty) {
      dangerBrokers.add(
        BrokerWrites(
          slot: b.slot,
          fields: dangerFields,
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

  final mqtt = p.mqtt;
  if (mqtt != null && !_blank(mqtt.regionIata)) {
    flats.add(FlatWrite(ConfigKeys.mqttIata, mqtt.regionIata!));
  }
  if (mqtt != null && mqtt.statusInterval != null) {
    flats.add(
      FlatWrite(ConfigKeys.mqttStatusInterval, '${mqtt.statusInterval}'),
    );
  }

  final brokers = <BrokerWrites>[];
  for (final b in (mqtt?.brokers ?? const <BrokerConfig>[])) {
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

    if (fields.isEmpty) continue; // nothing to write

    brokers.add(
      BrokerWrites(
        slot: b.slot,
        fields: fields,
        dangerFields: fields.keys.where(kDangerBrokerFields.contains).toSet(),
      ),
    );
  }

  return ProfileWrites(flats: flats, brokers: brokers);
}
