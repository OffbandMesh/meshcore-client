// Broker runtime-status mapping (#93, firmware #172/#173). Maps the additive
// `state` + `last_error` dump fields to the human status the UI shows, and
// parses the resolved-default placeholders. Absent fields (older firmware) must
// read as today's plain enabled/disabled.

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/observer_config.dart';

BrokerConfig _broker({
  bool enabled = true,
  BrokerRuntimeState state = BrokerRuntimeState.unknown,
  BrokerLastError lastError = BrokerLastError.none,
}) => BrokerConfig(
  slot: 0,
  url: 'mqtt.example',
  port: 1883,
  enabled: enabled,
  runtimeState: state,
  lastError: lastError,
);

void main() {
  group('BrokerConfig.status', () {
    test('disabled overrides any runtime state', () {
      final s = _broker(enabled: false, state: BrokerRuntimeState.up).status;
      expect(s.label, 'Disabled');
      expect(s.kind, BrokerStatusKind.disabled);
    });

    test('up -> Connected', () {
      final s = _broker(state: BrokerRuntimeState.up).status;
      expect(s.label, 'Connected');
      expect(s.kind, BrokerStatusKind.connected);
    });

    test('connecting -> Connecting', () {
      expect(
        _broker(state: BrokerRuntimeState.connecting).status.kind,
        BrokerStatusKind.connecting,
      );
    });

    test('backoff qualifies the failure with last_error', () {
      final s = _broker(
        state: BrokerRuntimeState.backoff,
        lastError: BrokerLastError.auth,
      ).status;
      expect(s.label, 'Failed (auth)');
      expect(s.kind, BrokerStatusKind.failed);
    });

    test('backoff with no error class -> plain Failed', () {
      final s = _broker(state: BrokerRuntimeState.backoff).status;
      expect(s.label, 'Failed');
      expect(s.kind, BrokerStatusKind.failed);
    });

    test('held states are neutral, not failures', () {
      expect(
        _broker(state: BrokerRuntimeState.heldNoClock).status.kind,
        BrokerStatusKind.held,
      );
      expect(
        _broker(state: BrokerRuntimeState.heldNoHeap).status.label,
        'Held — low heap',
      );
    });

    test('unknown state (older firmware) reads as plain Enabled', () {
      final s = _broker(state: BrokerRuntimeState.unknown).status;
      expect(s.label, 'Enabled');
      expect(s.kind, BrokerStatusKind.idle);
    });
  });

  group('BrokerConfig.fromWireFields runtime + resolved fields', () {
    test('parses state + last_error + resolved defaults', () {
      final b = BrokerConfig.fromWireFields(2, {
        'url': 'mqtt.example',
        'enabled': '1',
        'state': 'backoff',
        'last_error': 'tls',
        'jwt_owner_resolved': 'ABCDEF',
        'iata_resolved': 'HAO',
      });
      expect(b.runtimeState, BrokerRuntimeState.backoff);
      expect(b.lastError, BrokerLastError.tls);
      expect(b.jwtOwnerResolved, 'ABCDEF');
      expect(b.iataResolved, 'HAO');
      expect(b.status.label, 'Failed (tls)');
    });

    test('absent runtime fields default to unknown/none (backward compat)', () {
      final b = BrokerConfig.fromWireFields(0, {
        'url': 'mqtt.example',
        'enabled': '1',
      });
      expect(b.runtimeState, BrokerRuntimeState.unknown);
      expect(b.lastError, BrokerLastError.none);
      expect(b.jwtOwnerResolved, '');
      expect(b.iataResolved, '');
      expect(b.status.label, 'Enabled');
    });
  });
}
