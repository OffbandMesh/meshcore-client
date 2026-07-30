// Lock tests for the Offband config models (#64 M1).
//
// The models are the data structures untrusted wire fields decode into, so the
// defensive behavior (enum fallback, numeric fallback, secret presence) is
// pinned here. All green, M1 confirms the existing draft is contract-correct.

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/observer_config.dart';

void main() {
  group('enums fromWire / wire', () {
    test('BrokerTransport round-trips + rejects unknown', () {
      expect(BrokerTransport.fromWire('tcp'), BrokerTransport.tcp);
      expect(BrokerTransport.fromWire('tls'), BrokerTransport.tls);
      expect(BrokerTransport.fromWire('wss'), BrokerTransport.wss);
      expect(BrokerTransport.fromWire('bogus'), isNull);
      expect(BrokerTransport.tls.wire, 'tls');
    });

    test('BrokerAuthType round-trips + rejects unknown', () {
      expect(BrokerAuthType.fromWire('none'), BrokerAuthType.none);
      expect(BrokerAuthType.fromWire('jwt'), BrokerAuthType.jwt);
      expect(BrokerAuthType.fromWire('nope'), isNull);
      expect(BrokerAuthType.basic.wire, 'basic');
    });

    test('WifiStatus maps tokens, unknown -> unknown', () {
      expect(WifiStatus.fromWire('StaConnected'), WifiStatus.staConnected);
      expect(WifiStatus.fromWire('StaFailed'), WifiStatus.staFailed);
      expect(WifiStatus.fromWire('weird'), WifiStatus.unknown);
    });
  });

  group('BrokerConfig.fromWireFields', () {
    test('maps a fully-populated slot', () {
      final b = BrokerConfig.fromWireFields(3, {
        'enabled': '1',
        'url': 'mqtt://h',
        'port': '8883',
        'transport': 'tls',
        'auth_type': 'jwt',
        'username': 'u',
        'password': '(set)',
        'topic_prefix': 'p',
        'jwt_refresh': '900',
      });
      expect(b.slot, 3);
      expect(b.enabled, isTrue);
      expect(b.url, 'mqtt://h');
      expect(b.port, 8883);
      expect(b.transport, BrokerTransport.tls);
      expect(b.authType, BrokerAuthType.jwt);
      expect(b.username, 'u');
      expect(b.passwordSet, isTrue);
      expect(b.jwtRefresh, 900);
      expect(b.isPopulated, isTrue);
    });

    test('defaults + enum fallback on a sparse/garbage slot', () {
      final b = BrokerConfig.fromWireFields(0, {
        'transport': 'bogus',
        'auth_type': '?',
        'password': '(unset)',
      });
      expect(b.url, '');
      expect(b.port, 0);
      expect(b.transport, BrokerTransport.tcp); // unknown -> default
      expect(b.authType, BrokerAuthType.none); // unknown -> default
      expect(b.passwordSet, isFalse); // not "(set)"
      expect(b.isPopulated, isFalse); // no url
    });
  });

  group('SecretField three-state', () {
    test('unchanged / clear / set', () {
      expect(const SecretField.unchanged(), isA<SecretUnchanged>());
      expect(const SecretField.clear(), isA<SecretClear>());
      const s = SecretField.set('x');
      expect(s, isA<SecretSet>());
      expect((s as SecretSet).value, 'x');
    });
  });

  test('BrokerConfig.copyWith overrides selectively', () {
    const b = BrokerConfig(slot: 1, url: 'a', port: 1);
    final c = b.copyWith(url: 'b');
    expect(c.slot, 1);
    expect(c.url, 'b');
    expect(c.port, 1); // untouched
  });
}
