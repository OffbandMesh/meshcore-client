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

/// Outcome of verifying that a broker enable/disable actually took effect, by
/// re-reading the slot after the SET (#89). A firmware build can ACK a toggle as
/// success without applying it (meshcore-firmware#179), so the UI never trusts
/// the ACK alone — it re-reads and reports what the device actually says.
enum BrokerApplyOutcome {
  /// Re-read confirms the device is in the intended enabled state.
  applied,

  /// The device ACKed success but the re-read shows the unchanged state — it did
  /// not apply the toggle. Surfaced as a warning, never a false success.
  notApplied,

  /// The re-read itself failed (timeout/disconnect — e.g. an enable that rebooted
  /// the device), so the result can't be confirmed either way.
  unverified,
}

/// Live runtime state of a broker connection, from the additive `state` field in
/// the OCFG_BROKERS dump (firmware #172). `unknown` = field absent (older
/// firmware) ⇒ the UI falls back to plain enabled/disabled.
enum BrokerRuntimeState {
  down,
  connecting,
  up,
  backoff,
  heldNoClock,
  heldNoHeap,
  unknown;

  static BrokerRuntimeState fromWire(String? s) {
    switch (s) {
      case 'down':
        return BrokerRuntimeState.down;
      case 'connecting':
        return BrokerRuntimeState.connecting;
      case 'up':
        return BrokerRuntimeState.up;
      case 'backoff':
        return BrokerRuntimeState.backoff;
      case 'held_no_clock':
        return BrokerRuntimeState.heldNoClock;
      case 'held_no_heap':
        return BrokerRuntimeState.heldNoHeap;
      default:
        return BrokerRuntimeState.unknown;
    }
  }
}

/// Last connection error class, from the additive `last_error` field (firmware
/// #172). Qualifies a [BrokerRuntimeState.backoff] failure.
enum BrokerLastError {
  none,
  tcp,
  auth,
  tls,
  other;

  static BrokerLastError fromWire(String? s) {
    switch (s) {
      case 'tcp':
        return BrokerLastError.tcp;
      case 'auth':
        return BrokerLastError.auth;
      case 'tls':
        return BrokerLastError.tls;
      case 'other':
        return BrokerLastError.other;
      default:
        return BrokerLastError.none;
    }
  }
}

/// Display category for a broker's status line — drives the label colour/icon.
enum BrokerStatusKind { connected, connecting, failed, held, idle, disabled }

/// A broker's human-facing status: a [label] plus a [kind] the UI colours.
class BrokerStatus {
  const BrokerStatus(this.label, this.kind);
  final String label;
  final BrokerStatusKind kind;
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
    this.runtimeState = BrokerRuntimeState.unknown,
    this.lastError = BrokerLastError.none,
    this.jwtOwnerResolved = '',
    this.iataResolved = '',
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

  /// Live runtime state (firmware #172); [BrokerRuntimeState.unknown] when the
  /// device doesn't report it (older firmware).
  final BrokerRuntimeState runtimeState;

  /// Last connection error class, qualifying a [BrokerRuntimeState.backoff] (#172).
  final BrokerLastError lastError;

  /// Resolved defaults shown as greyed hints when the raw key is blank (#173).
  /// Never written back — the blank raw key stays the source of truth.
  final String jwtOwnerResolved;
  final String iataResolved;

  /// A slot is occupied iff it has a URL (firmware `cfg.url[0] != '\0'`).
  bool get isPopulated => url.isNotEmpty;

  /// Why this broker can't be safely enabled, or null if complete. Shared by
  /// the editor's pre-save check and the list's quick Enable so the client
  /// never activates a broker that can't work (#80).
  String? get enableError {
    if (url.isEmpty) return 'URL is required';
    if (port < 1 || port > 65535) return 'Port must be between 1 and 65535';
    // JWT owner (device pubkey), IATA override, etc. are firmware-defaulted, so
    // the client does NOT gate them — the firmware enforces with its defaults.
    return null;
  }

  /// Classify whether a toggle/save took, comparing the [intendedEnabled] state
  /// to a re-read [actualEnabled] (null = the re-read failed). Pure and
  /// device-agnostic: it reports only what the device reported back, never
  /// assuming a change took that the device didn't confirm (#89).
  static BrokerApplyOutcome classifyApply({
    required bool intendedEnabled,
    required bool? actualEnabled,
  }) {
    if (actualEnabled == null) return BrokerApplyOutcome.unverified;
    return actualEnabled == intendedEnabled
        ? BrokerApplyOutcome.applied
        : BrokerApplyOutcome.notApplied;
  }

  /// Human-facing status, derived from [enabled] + [runtimeState] + [lastError]
  /// (#172). When the device doesn't report runtime state ([runtimeState] is
  /// [BrokerRuntimeState.unknown], e.g. older firmware) this is the plain
  /// enabled/disabled the UI showed before — so absent fields read as today.
  BrokerStatus get status {
    if (!enabled) {
      return const BrokerStatus('Disabled', BrokerStatusKind.disabled);
    }
    switch (runtimeState) {
      case BrokerRuntimeState.up:
        return const BrokerStatus('Connected', BrokerStatusKind.connected);
      case BrokerRuntimeState.connecting:
        return const BrokerStatus('Connecting…', BrokerStatusKind.connecting);
      case BrokerRuntimeState.backoff:
        final reason = lastError == BrokerLastError.none
            ? ''
            : ' (${lastError.name})';
        return BrokerStatus('Failed$reason', BrokerStatusKind.failed);
      case BrokerRuntimeState.heldNoClock:
        return const BrokerStatus('Held — no clock', BrokerStatusKind.held);
      case BrokerRuntimeState.heldNoHeap:
        return const BrokerStatus('Held — low heap', BrokerStatusKind.held);
      case BrokerRuntimeState.down:
      case BrokerRuntimeState.unknown:
        return const BrokerStatus('Enabled', BrokerStatusKind.idle);
    }
  }

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
      runtimeState: BrokerRuntimeState.fromWire(kv['state']),
      lastError: BrokerLastError.fromWire(kv['last_error']),
      jwtOwnerResolved: kv['jwt_owner_resolved'] ?? '',
      iataResolved: kv['iata_resolved'] ?? '',
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
    BrokerRuntimeState? runtimeState,
    BrokerLastError? lastError,
    String? jwtOwnerResolved,
    String? iataResolved,
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
      runtimeState: runtimeState ?? this.runtimeState,
      lastError: lastError ?? this.lastError,
      jwtOwnerResolved: jwtOwnerResolved ?? this.jwtOwnerResolved,
      iataResolved: iataResolved ?? this.iataResolved,
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
