import 'package:yaml/yaml.dart';

import '../models/config_profile.dart';

/// Thrown when a config-profile document is not valid (#403).
///
/// Message is user-facing: the import flow shows it verbatim, so it names the
/// offending key/value rather than a stack position.
class ConfigProfileFormatException implements Exception {
  const ConfigProfileFormatException(this.message);
  final String message;
  @override
  String toString() => 'ConfigProfileFormatException: $message';
}

/// Parse a YAML config profile into a [ConfigProfile] (#402 model).
///
/// Strict by design — profiles are untrusted input (#139 trust note), so an
/// unknown key or a wrong type is an error, not a silent skip. Only keys present
/// in the document appear in the model; everything else stays null so the apply
/// engines touch only what the profile sets.
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

  final root = _asMap(doc, 'document root');

  final version = _requireInt(root, 'schema_version');
  if (version > kConfigProfileSchemaVersion) {
    throw ConfigProfileFormatException(
      'Profile schema_version $version is newer than this app supports '
      '($kConfigProfileSchemaVersion). Update the app.',
    );
  }

  _rejectUnknownKeys(root, const {
    'schema_version',
    'name',
    'wifi',
    'region',
    'status_interval',
    'brokers',
  }, 'document root');

  return ConfigProfile(
    schemaVersion: version,
    name: _optString(root, 'name'),
    wifi: _parseWifi(root['wifi']),
    regionIata: _optString(root, 'region'),
    statusInterval: _optInt(root, 'status_interval'),
    brokers: _parseBrokers(root['brokers']),
  );
}

WifiConfig? _parseWifi(dynamic node) {
  if (node == null) return null;
  final map = _asMap(node, 'wifi');
  _rejectUnknownKeys(map, const {'ssid', 'password', 'enabled'}, 'wifi');
  return WifiConfig(
    ssid: _optString(map, 'ssid'),
    password: _optString(map, 'password'),
    enabled: _optBool(map, 'enabled'),
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
    final map = _asMap(node[i], 'brokers[$i]');
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
    }, 'brokers[$i]');

    final slot = _requireInt(map, 'slot', context: 'brokers[$i]');
    if (slot < 0 || slot >= kMaxBrokerSlots) {
      throw ConfigProfileFormatException(
        'brokers[$i].slot must be 0..${kMaxBrokerSlots - 1}, got $slot',
      );
    }
    if (!seenSlots.add(slot)) {
      throw ConfigProfileFormatException('duplicate broker slot $slot');
    }

    brokers.add(
      BrokerConfig(
        slot: slot,
        enabled: _optBool(map, 'enabled'),
        url: _optString(map, 'url'),
        port: _optInt(map, 'port'),
        transport: _optEnum(
          map,
          'transport',
          MqttTransport.fromWire,
          'tcp/tls/wss',
        ),
        authType: _optEnum(
          map,
          'auth_type',
          MqttAuthType.fromWire,
          'none/basic/jwt',
        ),
        username: _optString(map, 'username'),
        password: _optString(map, 'password'),
        jwtToken: _optString(map, 'jwt_token'),
        jwtAudience: _optString(map, 'jwt_aud'),
        jwtRefresh: _optInt(map, 'jwt_refresh'),
        jwtOwner: _optString(map, 'jwt_owner'),
        jwtEmail: _optString(map, 'jwt_email'),
        caCert: _optString(map, 'ca_cert'),
        topicPrefix: _optString(map, 'topic_prefix'),
        iataOverride: _optString(map, 'iata_override'),
      ),
    );
  }
  return brokers;
}

// --- typed accessors -------------------------------------------------------

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

int _requireInt(Map map, String key, {String context = 'document root'}) {
  final v = map[key];
  if (v == null) {
    throw ConfigProfileFormatException('$context is missing required "$key"');
  }
  if (v is! int) {
    throw ConfigProfileFormatException('$context."$key" must be an integer');
  }
  return v;
}

String? _optString(Map map, String key) {
  final v = map[key];
  if (v == null) return null;
  if (v is! String) {
    throw ConfigProfileFormatException('"$key" must be a string');
  }
  return v;
}

int? _optInt(Map map, String key) {
  final v = map[key];
  if (v == null) return null;
  if (v is! int) {
    throw ConfigProfileFormatException('"$key" must be an integer');
  }
  return v;
}

bool? _optBool(Map map, String key) {
  final v = map[key];
  if (v == null) return null;
  if (v is! bool) {
    throw ConfigProfileFormatException('"$key" must be true or false');
  }
  return v;
}

T? _optEnum<T>(
  Map map,
  String key,
  T? Function(String?) fromWire,
  String allowed,
) {
  final v = map[key];
  if (v == null) return null;
  if (v is! String) {
    throw ConfigProfileFormatException('"$key" must be a string ($allowed)');
  }
  final parsed = fromWire(v);
  if (parsed == null) {
    throw ConfigProfileFormatException(
      '"$key" must be one of $allowed, got "$v"',
    );
  }
  return parsed;
}
