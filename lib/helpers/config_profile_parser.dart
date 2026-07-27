import 'package:yaml/yaml.dart';

import '../models/config_profile.dart';

/// Thrown when a config-profile document is not valid (#403).
///
/// Message is user-facing: the import flow shows it verbatim, so it names the
/// offending key/value (with its section) rather than a stack position.
class ConfigProfileFormatException implements Exception {
  const ConfigProfileFormatException(this.message);
  final String message;
  @override
  String toString() => 'ConfigProfileFormatException: $message';
}

/// Parse a YAML config profile into a [ConfigProfile] (#402 model).
///
/// Strict by design — profiles are untrusted input (#139 trust note), so an
/// unknown key, a wrong type, or an out-of-range value is an error, not a silent
/// skip. Only keys present in the document appear in the model; everything else
/// stays null so the apply engines touch only what the profile sets.
///
/// Expected shape:
/// ```yaml
/// schema_version: 1
/// name: "US wide-area"      # optional label, not applied
/// wifi: { ssid: "...", password: "...", enabled: true }
/// region: "IAD"             # -> mqtt.iata
/// status_interval: 60
/// brokers:
///   - slot: 0
///     enabled: true
///     url: "..."
///     port: 8883
///     transport: tls        # tcp | tls | wss
///     auth_type: basic      # none | basic | jwt
///     username: "..."
///     ...
/// ```
ConfigProfile parseConfigProfile(String source) {
  final dynamic doc;
  try {
    doc = loadYaml(source);
  } on YamlException catch (e) {
    throw ConfigProfileFormatException('Not valid YAML: ${e.message}');
  }

  const root = 'document root';
  final map = _asMap(doc, root);

  final version = _requireInt(map, 'schema_version', root);
  if (version > kConfigProfileSchemaVersion) {
    throw ConfigProfileFormatException(
      'Profile schema_version $version is newer than this app supports '
      '($kConfigProfileSchemaVersion). Update the app.',
    );
  }

  _rejectUnknownKeys(map, const {
    'schema_version',
    'name',
    'wifi',
    'region',
    'status_interval',
    'brokers',
  }, root);

  return ConfigProfile(
    schemaVersion: version,
    name: _optString(map, 'name', root),
    wifi: _parseWifi(map['wifi']),
    regionIata: _optString(map, 'region', root),
    statusInterval: _optUint(map, 'status_interval', root),
    brokers: _parseBrokers(map['brokers']),
  );
}

WifiConfig? _parseWifi(dynamic node) {
  if (node == null) return null;
  const ctx = 'wifi';
  final map = _asMap(node, ctx);
  _rejectUnknownKeys(map, const {'ssid', 'password', 'enabled'}, ctx);
  return WifiConfig(
    ssid: _optString(map, 'ssid', ctx),
    password: _optString(map, 'password', ctx),
    enabled: _optBool(map, 'enabled', ctx),
  );
}

List<BrokerConfig> _parseBrokers(dynamic node) {
  if (node == null) return const [];
  if (node is! YamlList) {
    throw const ConfigProfileFormatException('"brokers" must be a list');
  }
  final seenSlots = <int>{};
  final brokers = <BrokerConfig>[];
  for (var i = 0; i < node.length; i++) {
    final ctx = 'brokers[$i]';
    final map = _asMap(node[i], ctx);
    _rejectUnknownKeys(map, const {
      'slot',
      'enabled',
      'url',
      'port',
      'transport',
      'auth_type',
      'username',
      'password',
      'jwt_token',
      'jwt_aud',
      'jwt_refresh',
      'jwt_owner',
      'jwt_email',
      'ca_cert',
      'topic_prefix',
      'iata_override',
    }, ctx);

    final slot = _requireInt(map, 'slot', ctx);
    if (slot < 0 || slot >= kMaxBrokerSlots) {
      throw ConfigProfileFormatException(
        '$ctx.slot must be 0..${kMaxBrokerSlots - 1}, got $slot',
      );
    }
    if (!seenSlots.add(slot)) {
      throw ConfigProfileFormatException('duplicate broker slot $slot');
    }

    final port = _optUint(map, 'port', ctx);
    if (port != null && (port < 1 || port > 65535)) {
      throw ConfigProfileFormatException(
        '$ctx.port must be 1..65535, got $port',
      );
    }

    brokers.add(
      BrokerConfig(
        slot: slot,
        enabled: _optBool(map, 'enabled', ctx),
        url: _optString(map, 'url', ctx),
        port: port,
        transport: _optEnum(
          map,
          'transport',
          ctx,
          MqttTransport.fromWire,
          'tcp/tls/wss',
        ),
        authType: _optEnum(
          map,
          'auth_type',
          ctx,
          MqttAuthType.fromWire,
          'none/basic/jwt',
        ),
        username: _optString(map, 'username', ctx),
        password: _optString(map, 'password', ctx),
        jwtToken: _optString(map, 'jwt_token', ctx),
        jwtAudience: _optString(map, 'jwt_aud', ctx),
        jwtRefresh: _optUint(map, 'jwt_refresh', ctx),
        jwtOwner: _optString(map, 'jwt_owner', ctx),
        jwtEmail: _optString(map, 'jwt_email', ctx),
        caCert: _optString(map, 'ca_cert', ctx),
        topicPrefix: _optString(map, 'topic_prefix', ctx),
        iataOverride: _optString(map, 'iata_override', ctx),
      ),
    );
  }
  return brokers;
}

// --- typed accessors (all name their section for user-facing errors) --------

Map _asMap(dynamic node, String what) {
  if (node is Map) return node;
  throw ConfigProfileFormatException('$what must be a mapping');
}

void _rejectUnknownKeys(Map map, Set<String> allowed, String what) {
  for (final key in map.keys) {
    if (!allowed.contains(key)) {
      throw ConfigProfileFormatException('unknown key "$key" in $what');
    }
  }
}

int _requireInt(Map map, String key, String ctx) {
  final v = map[key];
  if (v == null) {
    throw ConfigProfileFormatException('$ctx is missing required "$key"');
  }
  if (v is! int) {
    throw ConfigProfileFormatException('$ctx."$key" must be an integer');
  }
  return v;
}

String? _optString(Map map, String key, String ctx) {
  final v = map[key];
  if (v == null) return null;
  if (v is! String) {
    throw ConfigProfileFormatException('$ctx."$key" must be a string');
  }
  return v;
}

/// Optional non-negative integer (durations, ports, counts). Rejects negatives
/// since every integer field in a profile is a count/port/interval.
int? _optUint(Map map, String key, String ctx) {
  final v = map[key];
  if (v == null) return null;
  if (v is! int) {
    throw ConfigProfileFormatException('$ctx."$key" must be an integer');
  }
  if (v < 0) {
    throw ConfigProfileFormatException('$ctx."$key" must not be negative');
  }
  return v;
}

bool? _optBool(Map map, String key, String ctx) {
  final v = map[key];
  if (v == null) return null;
  if (v is! bool) {
    throw ConfigProfileFormatException('$ctx."$key" must be true or false');
  }
  return v;
}

T? _optEnum<T>(
  Map map,
  String key,
  String ctx,
  T? Function(String?) fromWire,
  String allowed,
) {
  final v = map[key];
  if (v == null) return null;
  if (v is! String) {
    throw ConfigProfileFormatException(
      '$ctx."$key" must be a string ($allowed)',
    );
  }
  final parsed = fromWire(v);
  if (parsed == null) {
    throw ConfigProfileFormatException(
      '$ctx."$key" must be one of $allowed, got "$v"',
    );
  }
  return parsed;
}
