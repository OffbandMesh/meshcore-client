// Observer device configuration models.
//
// These mirror the firmware wire contract in the firmware repo's
// `examples/companion_radio/OffbandConfigProtocol.h` (CMD_OFFBAND_CONFIG 0xC0,
// Epic F #160-#163). The device NVS is the single source of truth: the client
// holds no local copy — it reads via ObserverConfigClient and writes
// field-at-a-time. Secrets (password / wifi.pwd) are write-only on the wire.

/// MQTT broker transport. On the wire this is the string name
/// (`tcp` / `tls` / `wss`), never an ordinal (firmware WIRE ENCODING rule 1).
enum BrokerTransport {
  tcp,
  tls,
  wss;

  /// The wire token the firmware CLI parses and returns.
  String get wire => name;

  static BrokerTransport? fromWire(String s) {
    for (final t in BrokerTransport.values) {
      if (t.name == s) return t;
    }
    return null;
  }
}

/// MQTT broker authentication mode. Wire string is `none` / `basic` / `jwt`.
enum BrokerAuthType {
  none,
  basic,
  jwt;

  String get wire => name;

  static BrokerAuthType? fromWire(String s) {
    for (final a in BrokerAuthType.values) {
      if (a.name == s) return a;
    }
    return null;
  }
}

/// Live WiFi STA state reported by `get wifi.status` (read-only).
enum WifiStatus {
  boot,
  cliRescue,
  awaitingSetup,
  staConnecting,
  staConnected,
  staFailed,
  unknown;

  /// Firmware emits CamelCase tokens (`Boot`, `StaConnected`, …).
  static WifiStatus fromWire(String s) {
    switch (s) {
      case 'Boot':
        return WifiStatus.boot;
      case 'CliRescue':
        return WifiStatus.cliRescue;
      case 'AwaitingSetup':
        return WifiStatus.awaitingSetup;
      case 'StaConnecting':
        return WifiStatus.staConnecting;
      case 'StaConnected':
        return WifiStatus.staConnected;
      case 'StaFailed':
        return WifiStatus.staFailed;
      default:
        return WifiStatus.unknown;
    }
  }
}

/// Write intent for a write-only secret (broker `password`, `wifi.pwd`).
/// GET never returns the value, so an editor stages one of three intents and
/// the codec emits a SET only for [SecretClear] / [SecretSet].
sealed class SecretField {
  const SecretField();

  /// Leave the stored secret untouched — the codec sends nothing.
  const factory SecretField.unchanged() = SecretUnchanged;

  /// Clear the stored secret — the codec sends an empty value.
  const factory SecretField.clear() = SecretClear;

  /// Replace the stored secret — the codec sends [value].
  const factory SecretField.set(String value) = SecretSet;
}

class SecretUnchanged extends SecretField {
  const SecretUnchanged();
}

class SecretClear extends SecretField {
  const SecretClear();
}

class SecretSet extends SecretField {
  const SecretSet(this.value);
  final String value;
}

/// One MQTT broker slot (0-9), as read back from the `OCFG_BROKERS` dump.
/// Non-secret fields only — `password` is reported as presence ([passwordSet]),
/// `jwt_token` is never a config key.
class BrokerConfig {
  const BrokerConfig({
    required this.slot,
    this.enabled = false,
    this.url = '',
    this.port = 0,
    this.transport = BrokerTransport.tcp,
    this.authType = BrokerAuthType.none,
    this.username = '',
    this.passwordSet = false,
    this.topicPrefix = '',
    this.iataOverride = '',
    this.jwtAudience = '',
    this.jwtRefresh = 0,
    this.jwtOwner = '',
    this.jwtEmail = '',
    this.caCert = '',
  });

  final int slot;
  final bool enabled;
  final String url;
  final int port;
  final BrokerTransport transport;
  final BrokerAuthType authType;
  final String username;

  /// Whether a password is stored — from the wire `(set)` / `(unset)` token.
  /// The value itself is never returned.
  final bool passwordSet;
  final String topicPrefix;
  final String iataOverride;
  final String jwtAudience;
  final int jwtRefresh;
  final String jwtOwner;
  final String jwtEmail;
  final String caCert;

  /// A slot is occupied iff it has a URL (firmware `cfg.url[0] != '\0'`).
  bool get isPopulated => url.isNotEmpty;

  /// Build from one slot's decoded `key=value` lines (the OCFG_BROKER_KV bodies).
  /// Unknown keys are ignored; missing keys keep the defaults.
  factory BrokerConfig.fromWireFields(int slot, Map<String, String> kv) {
    int parseInt(String? v, int fallback) =>
        v == null ? fallback : (int.tryParse(v.trim()) ?? fallback);
    return BrokerConfig(
      slot: slot,
      enabled: kv['enabled'] == '1',
      url: kv['url'] ?? '',
      port: parseInt(kv['port'], 0),
      transport:
          BrokerTransport.fromWire(kv['transport'] ?? '') ??
          BrokerTransport.tcp,
      authType:
          BrokerAuthType.fromWire(kv['auth_type'] ?? '') ?? BrokerAuthType.none,
      username: kv['username'] ?? '',
      passwordSet: kv['password'] == '(set)',
      topicPrefix: kv['topic_prefix'] ?? '',
      iataOverride: kv['iata_override'] ?? '',
      jwtAudience: kv['jwt_audience'] ?? '',
      jwtRefresh: parseInt(kv['jwt_refresh'], 0),
      jwtOwner: kv['jwt_owner'] ?? '',
      jwtEmail: kv['jwt_email'] ?? '',
      caCert: kv['ca_cert'] ?? '',
    );
  }

  BrokerConfig copyWith({
    bool? enabled,
    String? url,
    int? port,
    BrokerTransport? transport,
    BrokerAuthType? authType,
    String? username,
    bool? passwordSet,
    String? topicPrefix,
    String? iataOverride,
    String? jwtAudience,
    int? jwtRefresh,
    String? jwtOwner,
    String? jwtEmail,
    String? caCert,
  }) {
    return BrokerConfig(
      slot: slot,
      enabled: enabled ?? this.enabled,
      url: url ?? this.url,
      port: port ?? this.port,
      transport: transport ?? this.transport,
      authType: authType ?? this.authType,
      username: username ?? this.username,
      passwordSet: passwordSet ?? this.passwordSet,
      topicPrefix: topicPrefix ?? this.topicPrefix,
      iataOverride: iataOverride ?? this.iataOverride,
      jwtAudience: jwtAudience ?? this.jwtAudience,
      jwtRefresh: jwtRefresh ?? this.jwtRefresh,
      jwtOwner: jwtOwner ?? this.jwtOwner,
      jwtEmail: jwtEmail ?? this.jwtEmail,
      caCert: caCert ?? this.caCert,
    );
  }

  /// An empty (unconfigured) slot.
  factory BrokerConfig.empty(int slot) => BrokerConfig(slot: slot);
}

/// WiFi settings. `wifi.pwd` is write-only (no read state); [status]/[ip] come
/// from the read-only `wifi.status`.
class WifiConfig {
  const WifiConfig({
    this.ssid = '',
    this.enabled = true,
    this.status = WifiStatus.unknown,
    this.ip,
  });

  final String ssid;
  final bool enabled;
  final WifiStatus status;
  final String? ip;

  WifiConfig copyWith({
    String? ssid,
    bool? enabled,
    WifiStatus? status,
    String? ip,
  }) {
    return WifiConfig(
      ssid: ssid ?? this.ssid,
      enabled: enabled ?? this.enabled,
      status: status ?? this.status,
      ip: ip ?? this.ip,
    );
  }
}

/// Pool-wide MQTT settings (`mqtt.iata`, `mqtt.status_interval`).
class MqttGlobalConfig {
  const MqttGlobalConfig({this.iata = '', this.statusInterval = 60});

  final String iata;

  /// Status publish interval in seconds (firmware range 10..3600).
  final int statusInterval;

  MqttGlobalConfig copyWith({String? iata, int? statusInterval}) {
    return MqttGlobalConfig(
      iata: iata ?? this.iata,
      statusInterval: statusInterval ?? this.statusInterval,
    );
  }
}

/// Display settings (`display.always_on`, `display.rotation` 0|180).
class DisplayConfig {
  const DisplayConfig({this.alwaysOn = false, this.rotation = 0});

  final bool alwaysOn;
  final int rotation; // 0 or 180

  DisplayConfig copyWith({bool? alwaysOn, int? rotation}) {
    return DisplayConfig(
      alwaysOn: alwaysOn ?? this.alwaysOn,
      rotation: rotation ?? this.rotation,
    );
  }
}

/// Full observer configuration snapshot read from the device.
class ObserverConfig {
  const ObserverConfig({
    this.wifi = const WifiConfig(),
    this.mqtt = const MqttGlobalConfig(),
    this.brokers = const <BrokerConfig>[],
    this.display = const DisplayConfig(),
  });

  final WifiConfig wifi;
  final MqttGlobalConfig mqtt;
  final List<BrokerConfig> brokers;
  final DisplayConfig display;

  ObserverConfig copyWith({
    WifiConfig? wifi,
    MqttGlobalConfig? mqtt,
    List<BrokerConfig>? brokers,
    DisplayConfig? display,
  }) {
    return ObserverConfig(
      wifi: wifi ?? this.wifi,
      mqtt: mqtt ?? this.mqtt,
      brokers: brokers ?? this.brokers,
      display: display ?? this.display,
    );
  }
}
