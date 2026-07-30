import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/helpers/config_profile_diff.dart';
import 'package:meshcore_open/helpers/config_profile_writes.dart';
import 'package:meshcore_open/models/config_profile.dart';

ProfileWrites _writes(ConfigProfile p) => enumerateProfileWrites(p);

void main() {
  group('buildProfileDiff', () {
    test('categorizes add vs change and drops unchanged', () {
      final w = _writes(
        const ConfigProfile(
          schemaVersion: 2,
          mqtt: MqttSection(regionIata: 'IAD', statusInterval: 60),
        ),
      );
      final d = buildProfileDiff(
        w,
        currentFlat: {
          ConfigKeys.mqttIata: 'LHR', // change
          ConfigKeys.mqttStatusInterval: '60', // unchanged -> dropped
        },
        currentBroker: const {},
      );
      expect(d.rows.length, 1);
      expect(d.rows.single.label, ConfigKeys.mqttIata);
      expect(d.rows.single.kind, DiffKind.change);
      expect(d.rows.single.oldValue, 'LHR');
      expect(d.rows.single.newValue, 'IAD');
    });

    test('add when device has no current value', () {
      final w = _writes(
        const ConfigProfile(
          schemaVersion: 2,
          mqtt: MqttSection(regionIata: 'IAD'),
        ),
      );
      final d = buildProfileDiff(
        w,
        currentFlat: const {},
        currentBroker: const {},
      );
      expect(d.rows.single.kind, DiffKind.add);
      expect(d.rows.single.oldValue, isNull);
    });

    test('flags danger + secret rows', () {
      final w = _writes(
        const ConfigProfile(
          schemaVersion: 2,
          wifi: WifiConfig(password: 'pw'),
          mqtt: MqttSection(
            brokers: [
              BrokerConfig(slot: 0, username: 'u', password: 'p', url: 'h'),
            ],
          ),
        ),
      );
      final d = buildProfileDiff(
        w,
        currentFlat: const {},
        currentBroker: const {},
      );
      expect(d.hasDanger, isTrue);
      // wifi.pwd + broker password + username are danger; url is not
      final danger = d.dangerRows.map((r) => r.label).toSet();
      expect(danger, contains(ConfigKeys.wifiPassword));
      expect(danger, contains('broker 0.${ConfigKeys.brokerPassword}'));
      expect(danger, contains('broker 0.${ConfigKeys.brokerUsername}'));
      expect(danger.contains('broker 0.${ConfigKeys.brokerUrl}'), isFalse);
      // secrets: password + wifi.pwd; username is danger but not secret
      final secrets = d.rows.where((r) => r.secret).map((r) => r.label).toSet();
      expect(secrets, {
        ConfigKeys.wifiPassword,
        'broker 0.${ConfigKeys.brokerPassword}',
      });
    });

    test('broker enabled change is a plain (non-danger) row', () {
      final w = _writes(
        const ConfigProfile(
          schemaVersion: 2,
          mqtt: MqttSection(
            brokers: [BrokerConfig(slot: 2, enabled: true, url: 'h')],
          ),
        ),
      );
      final d = buildProfileDiff(
        w,
        currentFlat: const {},
        currentBroker: {
          2: {ConfigKeys.brokerEnabled: '0', ConfigKeys.brokerUrl: 'h'},
        },
      );
      // url unchanged (h==h) dropped; enabled 0->1 present, not danger
      final labels = d.rows.map((r) => r.label).toList();
      expect(labels, ['broker 2.${ConfigKeys.brokerEnabled}']);
      expect(d.rows.single.danger, isFalse);
    });
  });
}
