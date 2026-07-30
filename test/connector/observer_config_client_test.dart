// Adversarial + correctness tests for the Offband config codec (#64 A1).
//
// TDD: the "hostile device" group is written to FAIL on the un-hardened codec,
// it documents the Gemini BLOCKER (unbounded BrokerListDecoder / DoS) and MINOR
// (out-of-range slot accepted). C1 (#72) hardens the codec until these pass.
// The builder / parsing / happy-path groups assert the contract and should be
// green already.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/observer_config_client.dart';
import 'package:meshcore_open/models/observer_config.dart';

void main() {
  Uint8List resp(int sub, [List<int>? payload]) {
    final b = BytesBuilder();
    b.addByte(ObserverConfigClient.respConfig);
    b.addByte(sub);
    if (payload != null) b.add(payload);
    return b.toBytes();
  }

  Uint8List respText(int sub, String text) =>
      resp(sub, [...utf8.encode(text), 0]);

  Uint8List brokerKv(int slot, String kv) => Uint8List.fromList([
    ObserverConfigClient.respConfig,
    ObserverConfigClient.rBrokerKv,
    slot,
    ...utf8.encode(kv),
    0,
  ]);

  group('frame builders', () {
    test('buildSet = [0xC0, OCFG_SET, "key value", NUL]', () {
      final f = ObserverConfigClient.buildSet('mqtt.iata', 'HAO');
      expect(f[0], ObserverConfigClient.cmdConfig);
      expect(f[1], ObserverConfigClient.opSet);
      expect(utf8.decode(f.sublist(2, f.length - 1)), 'mqtt.iata HAO');
      expect(f.last, 0);
    });

    test('buildGet / buildBrokers sub-types', () {
      expect(
        ObserverConfigClient.buildGet('wifi.ssid')[1],
        ObserverConfigClient.opGet,
      );
      final br = ObserverConfigClient.buildBrokers();
      expect(br.length, 2);
      expect(br[1], ObserverConfigClient.opBrokers);
    });

    test(
      'SET value with spaces is verbatim (first-space split is firmware-side)',
      () {
        final f = ObserverConfigClient.buildSet('wifi.ssid', 'My Home Net');
        expect(
          utf8.decode(f.sublist(2, f.length - 1)),
          'wifi.ssid My Home Net',
        );
      },
    );
  });

  group('response parsing', () {
    test('ACK / ERR / VALUE', () {
      expect(
        ObserverConfigClient.parse(respText(ObserverConfigClient.rAck, 'ok')),
        isA<ConfigAck>(),
      );
      expect(
        ObserverConfigClient.parse(
          respText(ObserverConfigClient.rErr, 'ERROR boom'),
        ),
        isA<ConfigErr>(),
      );
      final v = ObserverConfigClient.parse(
        respText(ObserverConfigClient.rValue, 'wifi.ssid = MyNet'),
      );
      expect(v, isA<ConfigValue>());
      expect((v as ConfigValue).value, 'MyNet');
    });

    test('wrong code -> ConfigUnknown', () {
      expect(
        ObserverConfigClient.parse(Uint8List.fromList([0x42, 0x00])),
        isA<ConfigUnknown>(),
      );
    });

    test('too-short frame -> ConfigUnknown', () {
      expect(
        ObserverConfigClient.parse(Uint8List.fromList([0xC0])),
        isA<ConfigUnknown>(),
      );
    });

    test('BROKER_KV splits on the FIRST = only (value may contain =)', () {
      final r =
          ObserverConfigClient.parse(brokerKv(0, 'url=mqtt://h/?a=b'))
              as ConfigBrokerKv;
      expect(r.slot, 0);
      expect(r.key, 'url');
      expect(r.value, 'mqtt://h/?a=b');
    });
  });

  group('broker decode, happy path', () {
    test('START -> KV -> END assembles a broker', () {
      final d = BrokerListDecoder();
      expect(
        d.add(
          ObserverConfigClient.parse(
            resp(ObserverConfigClient.rBrokersStart, [1]),
          ),
        ),
        isNull,
      );
      d.add(ObserverConfigClient.parse(brokerKv(0, 'url=mqtt://h')));
      d.add(ObserverConfigClient.parse(brokerKv(0, 'port=8883')));
      final list = d.add(
        ObserverConfigClient.parse(resp(ObserverConfigClient.rBrokersEnd)),
      );
      expect(list, isNotNull);
      expect(list!.length, 1);
      expect(list.first.url, 'mqtt://h');
      expect(list.first.port, 8883);
    });
  });

  // ---- ADVERSARIAL: assume a malicious/compromised device controls the wire ----
  group('adversarial: hostile device', () {
    test(
      'DoS, flood of BROKER_KV must not retain slots past brokerSlotCount',
      () {
        final d = BrokerListDecoder();
        d.add(
          ObserverConfigClient.parse(
            resp(ObserverConfigClient.rBrokersStart, [0]),
          ),
        );
        // Malicious device floods 1000 frames across 256 slots, far over the
        // 10-slot contract, then (eventually) END.
        for (var i = 0; i < 1000; i++) {
          d.add(
            ObserverConfigClient.parse(brokerKv(i % 256, 'url=mqtt://flood$i')),
          );
        }
        final list = d.add(
          ObserverConfigClient.parse(resp(ObserverConfigClient.rBrokersEnd)),
        );
        expect(
          list!.length,
          lessThanOrEqualTo(ObserverConfigClient.brokerSlotCount),
          reason:
              'BrokerListDecoder must bound retained slots to brokerSlotCount (DoS guard)',
        );
      },
    );

    test('out-of-range slot index is dropped, never surfaced', () {
      final d = BrokerListDecoder();
      d.add(
        ObserverConfigClient.parse(
          resp(ObserverConfigClient.rBrokersStart, [1]),
        ),
      );
      d.add(ObserverConfigClient.parse(brokerKv(200, 'url=mqtt://evil')));
      final list = d.add(
        ObserverConfigClient.parse(resp(ObserverConfigClient.rBrokersEnd)),
      );
      expect(
        list!.any((b) => b.slot >= ObserverConfigClient.brokerSlotCount),
        isFalse,
        reason: 'slots >= brokerSlotCount must be dropped, not stored',
      );
    });

    test('malformed: missing NUL terminator parses without throwing', () {
      final f = Uint8List.fromList([
        ObserverConfigClient.respConfig,
        ObserverConfigClient.rValue,
        ...utf8.encode('wifi.ssid = y'),
      ]);
      expect(() => ObserverConfigClient.parse(f), returnsNormally);
    });

    test('garbage numeric fields fall back to defaults, never throw', () {
      final b = BrokerConfig.fromWireFields(0, {
        'url': 'h',
        'port': 'NaN',
        'jwt_refresh': '',
      });
      expect(b.port, 0);
      expect(b.jwtRefresh, 0);
    });

    test('KV before START is ignored (no implicit accumulation)', () {
      final d = BrokerListDecoder();
      // No START, a stray KV must not be retained.
      d.add(ObserverConfigClient.parse(brokerKv(0, 'url=mqtt://stray')));
      final list = d.add(
        ObserverConfigClient.parse(resp(ObserverConfigClient.rBrokersEnd)),
      );
      // END with no open stream returns null (nothing to assemble).
      expect(list, isNull);
    });
  });
}
