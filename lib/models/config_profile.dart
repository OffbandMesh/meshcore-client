/// Importable device config-profile model (#402, feature #136).
///
/// A profile is a portable set of config values a user applies to a device
/// (observer #139, repeater #137, companion #138) instead of baked defaults.
/// This file defines only the schema and typed model, parsing (#403) and the
/// per-device apply engines live elsewhere.
///
/// Every field is nullable: a profile carries only the keys it wants to set, so
/// the apply engines can write field-at-a-time and leave everything else alone.
///
/// Key names and the wire encoding mirror the firmware config schema
/// (`meshcore-firmware/.../wifi_observer/ConfigSchema.h`). transport and
/// auth_type travel as their string names, not the NVS ordinals.
library;

/// Bumped when the on-disk/YAML shape changes incompatibly. The parser (#403)
/// rejects a profile whose declared version it does not understand.
/// v2 (#456): capability sections (`wifi`, `mqtt`, …). v1 was the flat layout.
const int kConfigProfileSchemaVersion = 2;

/// Number of broker slots the firmware exposes (`mqtt_b0`..`mqtt_b5`).
const int kMaxBrokerSlots = 6;

/// MQTT transport, wire value is the name (`tcp`/`tls`/`wss`), not the ordinal.
enum MqttTransport {
  tcp,
  tls,
  wss;

  String get wire => name;

  static MqttTransport? fromWire(String? v) {
    if (v == null) return null;
    for (final t in values) {
      if (t.name == v.toLowerCase()) return t;
    }
    return null;
  }
}

/// MQTT auth type, wire value is the name (`none`/`basic`/`jwt`).
enum MqttAuthType {
  none,
  basic,
  jwt;

  String get wire => name;

  static MqttAuthType? fromWire(String? v) {
    if (v == null) return null;
    for (final a in values) {
      if (a.name == v.toLowerCase()) return a;
    }
    return null;
  }
}

/// WiFi credentials (`wifi.*`). [password] maps to the firmware's `wifi.pwd`
/// and is write-only on the device (GET returns an error), so a profile can set
/// it but never round-trips it back.
class WifiConfig {
  const WifiConfig({this.ssid, this.password, this.enabled});

  final String? ssid;
  final String? password;
  final bool? enabled;

  bool get isEmpty => ssid == null && password == null && enabled == null;
}

/// One broker slot (`mqtt.broker.<slot>.*`). Sensitive fields ([password],
/// [jwtToken]) are included so a profile *can* carry them, but sharing a profile
/// with secrets is a trust concern the import flow must surface (#139 trust note).
class BrokerConfig {
  const BrokerConfig({
    required this.slot,
    this.url,
    this.port,
    this.transport,
    this.authType,
    this.username,
    this.password,
    this.jwtToken,
    this.jwtAudience,
    this.jwtRefresh,
    this.jwtOwner,
    this.jwtEmail,
    this.caCert,
    this.topicPrefix,
    this.iataOverride,
  });

  /// 0-based slot index, `0 <= slot < kMaxBrokerSlots`.
  ///
  /// Broker `enabled` is deliberately NOT a profile field (#456): enabling a
  /// broker is the operator's runtime decision (firmware ships slots disabled,
  /// opt-in per #262). A profile configures the connection; apply preserves the
  /// device's current enabled state.
  final int slot;
  final String? url;
  final int? port;
  final MqttTransport? transport;
  final MqttAuthType? authType;
  final String? username;
  final String? password;
  final String? jwtToken;
  final String? jwtAudience;
  final int? jwtRefresh;
  final String? jwtOwner;
  final String? jwtEmail;
  final String? caCert;
  final String? topicPrefix;
  final String? iataOverride;
}

/// The `mqtt` section — observer/MQTT capability. Shared by any device running
/// the observer role (observer, observer-repeater, observer-companion); never a
/// plain companion or plain repeater (#456).
class MqttSection {
  const MqttSection({
    this.regionIata,
    this.statusInterval,
    this.brokers = const [],
  });

  /// `mqtt.iata`, the region/IATA code.
  final String? regionIata;

  /// `mqtt.status_interval`, seconds between status publishes.
  final int? statusInterval;

  /// Populated broker slots only (sparse; each carries its [BrokerConfig.slot]).
  final List<BrokerConfig> brokers;

  bool get isEmpty =>
      regionIata == null && statusInterval == null && brokers.isEmpty;
}

/// A complete importable config profile — a set of capability-scoped sections
/// (#456). A device applies the sections it supports; the apply *mechanism* is
/// per-device, the section *schema* is per-capability and shared. Future
/// sections (`radio`, `repeater`, `companion`, `display`) slot in alongside.
class ConfigProfile {
  const ConfigProfile({
    required this.schemaVersion,
    this.name,
    this.wifi,
    this.mqtt,
  });

  final int schemaVersion;

  /// Optional human label (not applied to the device).
  final String? name;

  /// `wifi` section — any wifi-capable device.
  final WifiConfig? wifi;

  /// `mqtt` section — observer/MQTT capability.
  final MqttSection? mqtt;
}

/// Firmware config-key names. Callers (parser #403, apply engines) build keys
/// from these rather than hard-coding strings, so a firmware rename lands in one
/// place. Broker keys are `mqtt.broker.<slot>.<subkey>`.
abstract final class ConfigKeys {
  static const String wifiPrefix = 'wifi.';
  static const String wifiSsid = 'wifi.ssid';
  static const String wifiPassword = 'wifi.pwd';
  static const String wifiEnabled = 'wifi.enabled';

  static const String mqttIata = 'mqtt.iata';
  static const String mqttStatusInterval = 'mqtt.status_interval';

  static const String brokerPrefix = 'mqtt.broker.';

  // Broker sub-keys, appended after `mqtt.broker.<slot>.`.
  static const String brokerEnabled = 'enabled';
  static const String brokerUrl = 'url';
  static const String brokerPort = 'port';
  static const String brokerTransport = 'transport';
  static const String brokerAuthType = 'auth_type';
  static const String brokerUsername = 'username';
  static const String brokerPassword = 'password';
  static const String brokerJwtToken = 'jwt_token';
  static const String brokerJwtAudience = 'jwt_aud';
  static const String brokerJwtRefresh = 'jwt_refresh';
  static const String brokerJwtOwner = 'jwt_owner';
  static const String brokerJwtEmail = 'jwt_email';
  static const String brokerCaCert = 'ca_cert';
  static const String brokerTopicPrefix = 'topic_prefix';
  static const String brokerIataOverride = 'iata_override';

  /// Full key for a broker sub-key, e.g. `mqtt.broker.2.url`.
  static String broker(int slot, String subKey) => '$brokerPrefix$slot.$subKey';
}
