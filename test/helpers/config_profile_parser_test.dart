import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/helpers/config_profile_parser.dart';
import 'package:meshcore_open/models/config_profile.dart';

void main() {
  group('parseConfigProfile', () {
    test('parses a full sectioned profile', () {
      final p = parseConfigProfile('''
schema_version: 2
name: US wide-area
wifi:
  ssid: MyNet
  password: secret
  enabled: true
mqtt:
  region: IAD
  status_interval: 60
  brokers:
    - slot: 0
      url: mqtt.example.org
      port: 8883
      transport: tls
      auth_type: basic
      username: u
      password: p
      topic_prefix: meshcore
    - slot: 2
      transport: wss
      auth_type: jwt
      jwt_refresh: 3600
''');
      expect(p.schemaVersion, 2);
      expect(p.name, 'US wide-area');
      expect(p.wifi?.ssid, 'MyNet');
      expect(p.wifi?.enabled, true);
      expect(p.mqtt?.regionIata, 'IAD');
      expect(p.mqtt?.statusInterval, 60);
      expect(p.mqtt?.brokers.length, 2);

      final b0 = p.mqtt!.brokers.firstWhere((b) => b.slot == 0);
      expect(b0.url, 'mqtt.example.org');
      expect(b0.port, 8883);
      expect(b0.transport, MqttTransport.tls);
      expect(b0.authType, MqttAuthType.basic);

      final b2 = p.mqtt!.brokers.firstWhere((b) => b.slot == 2);
      expect(b2.transport, MqttTransport.wss);
      expect(b2.authType, MqttAuthType.jwt);
      expect(b2.jwtRefresh, 3600);
    });

    test('leaves unset sections null (partial profile)', () {
      final p = parseConfigProfile('schema_version: 2\nmqtt:\n  region: LHR\n');
      expect(p.mqtt?.regionIata, 'LHR');
      expect(p.wifi, isNull);
      expect(p.mqtt?.statusInterval, isNull);
      expect(p.mqtt?.brokers, isEmpty);
    });

    test('rejects invalid YAML', () {
      expect(
        () => parseConfigProfile('schema_version: 2\n  : bad'),
        throwsA(isA<ConfigProfileFormatException>()),
      );
    });

    test('requires schema_version', () {
      expect(
        () => parseConfigProfile('name: x\n'),
        throwsA(isA<ConfigProfileFormatException>()),
      );
    });

    test('rejects a newer schema_version', () {
      expect(
        () => parseConfigProfile('schema_version: 999\n'),
        throwsA(isA<ConfigProfileFormatException>()),
      );
    });

    test('rejects the old flat v1 layout', () {
      expect(
        () => parseConfigProfile('schema_version: 1\nregion: IAD\n'),
        throwsA(isA<ConfigProfileFormatException>()),
      );
    });

    test('rejects unknown top-level key', () {
      expect(
        () => parseConfigProfile('schema_version: 2\nbogus: 1\n'),
        throwsA(isA<ConfigProfileFormatException>()),
      );
    });

    test('rejects a top-level key that belongs in a section', () {
      // region moved under mqtt in v2; at top level it is now unknown.
      expect(
        () => parseConfigProfile('schema_version: 2\nregion: IAD\n'),
        throwsA(isA<ConfigProfileFormatException>()),
      );
    });

    test('rejects unknown mqtt key', () {
      expect(
        () => parseConfigProfile('schema_version: 2\nmqtt:\n  nope: 1\n'),
        throwsA(isA<ConfigProfileFormatException>()),
      );
    });

    test('rejects unknown broker key', () {
      expect(
        () => parseConfigProfile(
          'schema_version: 2\nmqtt:\n  brokers:\n    - slot: 0\n      nope: 1\n',
        ),
        throwsA(isA<ConfigProfileFormatException>()),
      );
    });

    test('rejects broker "enabled" (#456 — not a profile field)', () {
      expect(
        () => parseConfigProfile(
          'schema_version: 2\nmqtt:\n  brokers:\n    - slot: 0\n      enabled: true\n',
        ),
        throwsA(isA<ConfigProfileFormatException>()),
      );
    });

    test('rejects an out-of-range broker slot', () {
      expect(
        () => parseConfigProfile(
          'schema_version: 2\nmqtt:\n  brokers:\n    - slot: 9\n',
        ),
        throwsA(isA<ConfigProfileFormatException>()),
      );
    });

    test('rejects a duplicate broker slot', () {
      expect(
        () => parseConfigProfile(
          'schema_version: 2\nmqtt:\n  brokers:\n    - slot: 0\n    - slot: 0\n',
        ),
        throwsA(isA<ConfigProfileFormatException>()),
      );
    });

    test('rejects an unknown transport value', () {
      expect(
        () => parseConfigProfile(
          'schema_version: 2\nmqtt:\n  brokers:\n    - slot: 0\n      transport: carrier-pigeon\n',
        ),
        throwsA(isA<ConfigProfileFormatException>()),
      );
    });

    test('rejects a wrong type', () {
      expect(
        () => parseConfigProfile(
          'schema_version: 2\nmqtt:\n  status_interval: soon\n',
        ),
        throwsA(isA<ConfigProfileFormatException>()),
      );
    });

    test('rejects an out-of-range broker port', () {
      expect(
        () => parseConfigProfile(
          'schema_version: 2\nmqtt:\n  brokers:\n    - slot: 0\n      port: 70000\n',
        ),
        throwsA(isA<ConfigProfileFormatException>()),
      );
      expect(
        () => parseConfigProfile(
          'schema_version: 2\nmqtt:\n  brokers:\n    - slot: 0\n      port: 0\n',
        ),
        throwsA(isA<ConfigProfileFormatException>()),
      );
    });

    test('rejects negative integer fields', () {
      expect(
        () => parseConfigProfile(
          'schema_version: 2\nmqtt:\n  status_interval: -60\n',
        ),
        throwsA(isA<ConfigProfileFormatException>()),
      );
      expect(
        () => parseConfigProfile(
          'schema_version: 2\nmqtt:\n  brokers:\n    - slot: 0\n      jwt_refresh: -1\n',
        ),
        throwsA(isA<ConfigProfileFormatException>()),
      );
    });

    test('nested type errors name the broker section', () {
      try {
        parseConfigProfile(
          'schema_version: 2\nmqtt:\n  brokers:\n    - slot: 0\n      port: "x"\n',
        );
        fail('expected throw');
      } on ConfigProfileFormatException catch (e) {
        expect(e.message, contains('brokers[0]'));
      }
    });
  });
}
