import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/helpers/config_profile_writes.dart';
import 'package:meshcore_open/models/config_profile.dart';

void main() {
  group('enumerateProfileWrites', () {
    test('emits only set keys; wifi.enabled ordered last', () {
      final w = enumerateProfileWrites(
        const ConfigProfile(
          schemaVersion: 1,
          wifi: WifiConfig(ssid: 'net', password: 'pw', enabled: true),
          regionIata: 'IAD',
          statusInterval: 60,
        ),
      );
      final keys = w.flats.map((f) => f.key).toList();
      expect(keys, contains(ConfigKeys.wifiSsid));
      expect(keys, contains(ConfigKeys.mqttIata));
      // wifi.enabled must come after wifi.ssid/pwd
      expect(
        keys.indexOf(ConfigKeys.wifiEnabled),
        greaterThan(keys.indexOf(ConfigKeys.wifiSsid)),
      );
      expect(
        w.flats.firstWhere((f) => f.key == ConfigKeys.wifiEnabled).value,
        '1',
      );
    });

    test('skips null and empty values (never clobbers)', () {
      final w = enumerateProfileWrites(
        const ConfigProfile(
          schemaVersion: 1,
          wifi: WifiConfig(ssid: '', password: null, enabled: null),
          regionIata: null,
        ),
      );
      expect(w.isEmpty, isTrue);
    });

    test('skips jwt_token even when present', () {
      final w = enumerateProfileWrites(
        const ConfigProfile(
          schemaVersion: 1,
          brokers: [BrokerConfig(slot: 0, jwtToken: 'minted', url: 'h')],
        ),
      );
      final b = w.brokers.single;
      expect(b.fields.containsKey(ConfigKeys.brokerJwtToken), isFalse);
      expect(b.fields[ConfigKeys.brokerUrl], 'h');
    });

    test('enabled kept out of fields (executor writes it last)', () {
      final w = enumerateProfileWrites(
        const ConfigProfile(
          schemaVersion: 1,
          brokers: [BrokerConfig(slot: 1, url: 'h', enabled: true)],
        ),
      );
      final b = w.brokers.single;
      expect(b.fields.containsKey(ConfigKeys.brokerEnabled), isFalse);
      expect(b.enabled, true);
    });

    test('formats enums as wire strings and ints as text', () {
      final w = enumerateProfileWrites(
        const ConfigProfile(
          schemaVersion: 1,
          brokers: [
            BrokerConfig(
              slot: 0,
              port: 8883,
              transport: MqttTransport.tls,
              authType: MqttAuthType.jwt,
              jwtRefresh: 3600,
            ),
          ],
        ),
      );
      final f = w.brokers.single.fields;
      expect(f[ConfigKeys.brokerPort], '8883');
      expect(f[ConfigKeys.brokerTransport], 'tls');
      expect(f[ConfigKeys.brokerAuthType], 'jwt');
      expect(f[ConfigKeys.brokerJwtRefresh], '3600');
    });

    test('flags danger fields (creds/identity), not plain config', () {
      final w = enumerateProfileWrites(
        const ConfigProfile(
          schemaVersion: 1,
          wifi: WifiConfig(password: 'pw'),
          brokers: [
            BrokerConfig(
              slot: 0,
              url: 'h',
              username: 'u',
              password: 'p',
              jwtOwner: 'deadbeef',
              jwtEmail: 'a@b.c',
              jwtAudience: 'https://host',
            ),
          ],
        ),
      );
      expect(w.hasDanger, isTrue);
      final b = w.brokers.single;
      expect(b.dangerFields, {
        ConfigKeys.brokerUsername,
        ConfigKeys.brokerPassword,
        ConfigKeys.brokerJwtOwner,
        ConfigKeys.brokerJwtEmail,
      });
      // audience + url are not danger
      expect(b.dangerFields.contains(ConfigKeys.brokerJwtAudience), isFalse);
      expect(b.dangerFields.contains(ConfigKeys.brokerUrl), isFalse);
      // wifi.pwd is a danger flat
      expect(
        w.flats.firstWhere((f) => f.key == ConfigKeys.wifiPassword).danger,
        isTrue,
      );
    });

    test('a broker with nothing set is dropped', () {
      final w = enumerateProfileWrites(
        const ConfigProfile(schemaVersion: 1, brokers: [BrokerConfig(slot: 3)]),
      );
      expect(w.brokers, isEmpty);
    });
  });
}
