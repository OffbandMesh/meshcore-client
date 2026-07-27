import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/helpers/config_profile_parser.dart';
import 'package:meshcore_open/models/config_profile.dart';

void main() {
  group('parseConfigProfile', () {
    test('parses a full profile', () {
      final p = parseConfigProfile('''
schema_version: 1
name: US wide-area
wifi:
  ssid: MyNet
  password: secret
  enabled: true
region: IAD
status_interval: 60
brokers:
  - slot: 0
    enabled: true
    url: mqtt.example.org
    port: 8883
    transport: tls
    auth_type: basic
    username: u
    password: p
    topic_prefix: meshcore
  - slot: 2
    enabled: false
    transport: wss
    auth_type: jwt
    jwt_refresh: 3600
''');
      expect(p.schemaVersion, 1);
      expect(p.name, 'US wide-area');
      expect(p.wifi?.ssid, 'MyNet');
      expect(p.wifi?.enabled, true);
      expect(p.regionIata, 'IAD');
      expect(p.statusInterval, 60);
      expect(p.brokers.length, 2);

      final b0 = p.brokers.firstWhere((b) => b.slot == 0);
      expect(b0.url, 'mqtt.example.org');
      expect(b0.port, 8883);
      expect(b0.transport, MqttTransport.tls);
      expect(b0.authType, MqttAuthType.basic);

      final b2 = p.brokers.firstWhere((b) => b.slot == 2);
      expect(b2.enabled, false);
      expect(b2.transport, MqttTransport.wss);
      expect(b2.authType, MqttAuthType.jwt);
      expect(b2.jwtRefresh, 3600);
    });

    test('leaves unset keys null (partial profile)', () {
      final p = parseConfigProfile('schema_version: 1\nregion: LHR\n');
      expect(p.regionIata, 'LHR');
      expect(p.wifi, isNull);
      expect(p.statusInterval, isNull);
      expect(p.brokers, isEmpty);
    });

    test('rejects invalid YAML', () {
      expect(
        () => parseConfigProfile('schema_version: 1\n  : bad'),
        throwsA(isA<ConfigProfileFormatException>()),
      );
    });

    test('requires schema_version', () {
      expect(
        () => parseConfigProfile('region: IAD\n'),
        throwsA(isA<ConfigProfileFormatException>()),
      );
    });

    test('rejects a newer schema_version', () {
      expect(
        () => parseConfigProfile('schema_version: 999\n'),
        throwsA(isA<ConfigProfileFormatException>()),
      );
    });

    test('rejects unknown top-level key', () {
      expect(
        () => parseConfigProfile('schema_version: 1\nbogus: 1\n'),
        throwsA(isA<ConfigProfileFormatException>()),
      );
    });

    test('rejects unknown broker key', () {
      expect(
        () => parseConfigProfile(
          'schema_version: 1\nbrokers:\n  - slot: 0\n    nope: 1\n',
        ),
        throwsA(isA<ConfigProfileFormatException>()),
      );
    });

    test('rejects an out-of-range broker slot', () {
      expect(
        () => parseConfigProfile('schema_version: 1\nbrokers:\n  - slot: 9\n'),
        throwsA(isA<ConfigProfileFormatException>()),
      );
    });

    test('rejects a duplicate broker slot', () {
      expect(
        () => parseConfigProfile(
          'schema_version: 1\nbrokers:\n  - slot: 0\n  - slot: 0\n',
        ),
        throwsA(isA<ConfigProfileFormatException>()),
      );
    });

    test('rejects an unknown transport value', () {
      expect(
        () => parseConfigProfile(
          'schema_version: 1\nbrokers:\n  - slot: 0\n    transport: carrier-pigeon\n',
        ),
        throwsA(isA<ConfigProfileFormatException>()),
      );
    });

    test('rejects a wrong type', () {
      expect(
        () => parseConfigProfile('schema_version: 1\nstatus_interval: soon\n'),
        throwsA(isA<ConfigProfileFormatException>()),
      );
    });

    test('rejects an out-of-range broker port', () {
      expect(
        () => parseConfigProfile(
          'schema_version: 1\nbrokers:\n  - slot: 0\n    port: 70000\n',
        ),
        throwsA(isA<ConfigProfileFormatException>()),
      );
      expect(
        () => parseConfigProfile(
          'schema_version: 1\nbrokers:\n  - slot: 0\n    port: 0\n',
        ),
        throwsA(isA<ConfigProfileFormatException>()),
      );
    });

    test('rejects negative integer fields', () {
      expect(
        () => parseConfigProfile('schema_version: 1\nstatus_interval: -60\n'),
        throwsA(isA<ConfigProfileFormatException>()),
      );
      expect(
        () => parseConfigProfile(
          'schema_version: 1\nbrokers:\n  - slot: 0\n    jwt_refresh: -1\n',
        ),
        throwsA(isA<ConfigProfileFormatException>()),
      );
    });

    test('nested type errors name the broker section', () {
      try {
        parseConfigProfile(
          'schema_version: 1\nbrokers:\n  - slot: 0\n    port: "x"\n',
        );
        fail('expected throw');
      } on ConfigProfileFormatException catch (e) {
        expect(e.message, contains('brokers[0]'));
      }
    });
  });
}
