// Adversarial + correctness tests for ObserverConfigService (#64 A2).
//
// TDD: the concurrency and secret-redaction tests are written to FAIL on the
// current service — they document the Gemini BLOCKER (#1 race: "one request in
// flight" is assumed, not enforced) and MINOR (#6: secret key names leak into
// error strings). S1 (#73) hardens the service until these pass.
//
// The service only uses 4 members of MeshCoreConnector (receivedFrames,
// sendFrame, firmwareVerCode, offbandCaps), so a fake subclass injects frames
// without any production change.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/observer_config_client.dart';
import 'package:meshcore_open/services/observer_config_service.dart';

/// Test transport: overrides only what the service touches; injects responses.
class _FakeConnector extends MeshCoreConnector {
  final StreamController<Uint8List> _frames =
      StreamController<Uint8List>.broadcast();
  final List<Uint8List> sent = [];
  int? ver = 14;
  int? caps = 0x01;

  @override
  Stream<Uint8List> get receivedFrames => _frames.stream;

  @override
  int? get firmwareVerCode => ver;

  @override
  int? get offbandCaps => caps;

  @override
  Future<void> sendFrame(
    Uint8List data, {
    String? channelSendQueueId,
    bool expectsGenericAck = false,
  }) async {
    sent.add(data);
  }

  void inject(Uint8List frame) => _frames.add(frame);
  void close() => _frames.close();
}

/// Auto-responds to each request so refresh()'s round-trips complete without
/// manual interleaving. [failKeys] answer ERR; others answer VALUE; the broker
/// dump is an empty pool (START -> END).
class _AutoConnector extends MeshCoreConnector {
  _AutoConnector({this.failKeys = const {}, this.failBrokers = false});
  final Set<String> failKeys;
  final bool failBrokers;
  final List<Uint8List> sent = [];
  final StreamController<Uint8List> _frames =
      StreamController<Uint8List>.broadcast();

  @override
  Stream<Uint8List> get receivedFrames => _frames.stream;
  @override
  int? get firmwareVerCode => 14;
  @override
  int? get offbandCaps => 0x01;

  @override
  Future<void> sendFrame(
    Uint8List data, {
    String? channelSendQueueId,
    bool expectsGenericAck = false,
  }) async {
    sent.add(data);
    final op = data[1];
    if (op == ObserverConfigClient.opGet) {
      final key = utf8.decode(data.sublist(2, data.length - 1));
      final frame = failKeys.contains(key)
          ? _resp(ObserverConfigClient.rErr, 'ERROR not available')
          : _resp(ObserverConfigClient.rValue, '$key = ${_valueFor(key)}');
      Future.microtask(() => _frames.add(frame));
    } else if (op == ObserverConfigClient.opSet) {
      // SET payload is "key value"; the key is everything before the 1st space.
      final payload = utf8.decode(data.sublist(2, data.indexOf(0, 2)));
      final key = payload.split(' ').first;
      final frame = failKeys.contains(key)
          ? _resp(ObserverConfigClient.rErr, 'ERROR not available')
          : _resp(ObserverConfigClient.rAck, '$key = ok');
      Future.microtask(() => _frames.add(frame));
    } else if (op == ObserverConfigClient.opBrokers) {
      if (failBrokers) return; // no response -> getBrokers times out
      Future.microtask(() {
        _frames.add(
          Uint8List.fromList([
            ObserverConfigClient.respConfig,
            ObserverConfigClient.rBrokersStart,
            0,
          ]),
        );
        _frames.add(
          Uint8List.fromList([
            ObserverConfigClient.respConfig,
            ObserverConfigClient.rBrokersEnd,
          ]),
        );
      });
    }
  }

  String _valueFor(String key) => switch (key) {
    'wifi.enabled' => '1',
    'display.always_on' => '0',
    'mqtt.status_interval' => '60',
    'display.rotation' => '0',
    'wifi.status' => 'StaConnected',
    _ => 'x',
  };

  Uint8List _resp(int sub, String text) => Uint8List.fromList([
    ObserverConfigClient.respConfig,
    sub,
    ...utf8.encode(text),
    0,
  ]);

  void closeStream() => _frames.close();
}

Uint8List _respText(int sub, String text) => Uint8List.fromList([
  ObserverConfigClient.respConfig,
  sub,
  ...utf8.encode(text),
  0,
]);

Uint8List _brokersStart(int count) => Uint8List.fromList([
  ObserverConfigClient.respConfig,
  ObserverConfigClient.rBrokersStart,
  count,
]);

Uint8List _brokerKv(int slot, String key, String value) => Uint8List.fromList([
  ObserverConfigClient.respConfig,
  ObserverConfigClient.rBrokerKv,
  slot,
  ...utf8.encode('$key=$value'),
  0,
]);

Uint8List _brokersEnd() => Uint8List.fromList([
  ObserverConfigClient.respConfig,
  ObserverConfigClient.rBrokersEnd,
]);

Future<void> _tick() => Future<void>.delayed(const Duration(milliseconds: 10));

void main() {
  late _FakeConnector c;
  late ObserverConfigService svc;

  setUp(() {
    c = _FakeConnector();
    svc = ObserverConfigService(c);
  });
  tearDown(() => c.close());

  test('supported reflects version gate + capability bit', () {
    expect(svc.supported, isTrue);
    c.caps = 0x00; // observer bit off
    expect(svc.supported, isFalse);
    c.caps = 0x01;
    c.ver = 13; // below gate
    expect(svc.supported, isFalse);
  });

  test('setFlat returns true on ACK (happy path)', () async {
    final f = svc.setFlat('mqtt.iata', 'HAO');
    await _tick();
    c.inject(_respText(ObserverConfigClient.rAck, 'mqtt.iata = HAO'));
    expect(await f, isTrue);
    // The frame actually went out.
    expect(c.sent.single[0], ObserverConfigClient.cmdConfig);
  });

  // ---- BLOCKER #1: single-flight is assumed but unenforced ----
  test('overlapping requests must NOT cross responses (single-flight)', () async {
    final getF = svc.getFlat('wifi.ssid');
    final setF = svc.setFlat('mqtt.iata', 'HAO');
    await _tick();
    // Device answers the GET first, then the SET.
    c.inject(_respText(ObserverConfigClient.rValue, 'wifi.ssid = MyNet'));
    await _tick();
    c.inject(_respText(ObserverConfigClient.rAck, 'mqtt.iata = HAO'));
    await _tick();
    expect(await getF, 'MyNet');
    expect(
      await setF,
      isTrue,
      reason:
          'setFlat must receive its OWN ACK, not the GET value — cross-talk means single-flight is unenforced',
    );
  });

  // ---- MINOR #6: secret key names leak into error messages ----
  test('error for a secret key does not leak the key name or value', () async {
    svc.timeout = const Duration(milliseconds: 30);
    final res = await svc.setFlat(
      'wifi.pwd',
      'hunter2',
    ); // no response -> timeout
    expect(res, isFalse);
    expect(svc.lastError, isNotNull);
    final err = svc.lastError!.toLowerCase();
    expect(
      err,
      isNot(contains('pwd')),
      reason: 'secret key name (wifi.pwd) must be redacted from errors',
    );
    expect(
      err,
      isNot(contains('hunter2')),
      reason: 'secret value must never appear in an error',
    );
  });

  // ---- MINOR-A (#78): a partial read failure must stay visible ----
  test(
    'refresh keeps the error visible + stale on a partial read failure',
    () async {
      final auto = _AutoConnector(failKeys: {'wifi.ssid'});
      final s = ObserverConfigService(auto);
      await s.refresh();
      expect(
        s.stale,
        isTrue,
        reason: 'a failed field must mark the snapshot stale',
      );
      expect(
        s.lastError,
        isNotNull,
        reason: 'a failed GET error must not be wiped by partial success',
      );
      auto.closeStream();
    },
  );

  test('refresh clears the error + is not stale on a full read', () async {
    final auto = _AutoConnector();
    final s = ObserverConfigService(auto);
    await s.refresh();
    expect(s.stale, isFalse);
    expect(s.lastError, isNull);
    auto.closeStream();
  });

  // ---- #79: a broker-dump failure must not blank the flat settings ----
  test(
    'broker-dump failure keeps flat settings + flags brokers unavailable',
    () async {
      final auto = _AutoConnector(failBrokers: true);
      final s = ObserverConfigService(auto);
      s.timeout = const Duration(milliseconds: 50);
      await s.refresh();
      expect(
        s.config,
        isNotNull,
        reason: 'settings that read cleanly must still show',
      );
      expect(s.config!.wifi.ssid, 'x');
      expect(s.brokersUnavailable, isTrue);
      expect(
        s.stale,
        isFalse,
        reason: 'a broker-dump miss is not a stale snapshot',
      );
      auto.closeStream();
    },
  );

  // ---- #81: a flat refresh must not re-pull the broker dump ----
  test(
    'refresh(includeBrokers:false) skips the broker dump, keeps brokers',
    () async {
      final auto = _AutoConnector();
      final s = ObserverConfigService(auto);
      int brokerReqs() => auto.sent
          .where((f) => f.length > 1 && f[1] == ObserverConfigClient.opBrokers)
          .length;
      await s.refresh(); // full read sends one OCFG_BROKERS
      expect(brokerReqs(), 1, reason: 'full refresh dumps the pool');
      await s.refresh(includeBrokers: false); // flat-only
      expect(
        brokerReqs(),
        1,
        reason: 'includeBrokers:false must NOT send another OCFG_BROKERS',
      );
      expect(s.config, isNotNull);
      auto.closeStream();
    },
  );

  // ---- #80: broker save handshake (enabled-last, per-field ACK, recovery) ----
  List<String> setKeys(_AutoConnector c) => c.sent
      .where((f) => f.length > 2 && f[1] == ObserverConfigClient.opSet)
      .map((f) => utf8.decode(f.sublist(2, f.indexOf(0, 2))).split(' ').first)
      .toList();

  test(
    'saveBroker on a live slot disables first, writes fields, enables LAST',
    () async {
      final auto = _AutoConnector();
      final s = ObserverConfigService(auto);
      final r = await s.saveBroker(
        2,
        fields: {'url': 'mqtt://h', 'port': '1883'},
        enable: true,
        wasLive: true,
      );
      expect(r.ok, isTrue);
      final keys = setKeys(auto);
      expect(
        keys.first,
        'mqtt.broker.2.enabled',
        reason: 'a live slot is disabled first',
      );
      expect(
        keys.last,
        'mqtt.broker.2.enabled',
        reason: 'enabled is written LAST (activation guard)',
      );
      expect(keys.where((k) => k == 'mqtt.broker.2.enabled').length, 2);
      expect(
        keys.indexOf('mqtt.broker.2.url'),
        greaterThan(keys.indexOf('mqtt.broker.2.enabled')),
      );
      expect(
        keys.indexOf('mqtt.broker.2.port'),
        lessThan(keys.lastIndexOf('mqtt.broker.2.enabled')),
      );
      auto.closeStream();
    },
  );

  test('saveBroker stops on a field ERR and never reaches the enabled-last '
      'activation', () async {
    final auto = _AutoConnector(failKeys: {'mqtt.broker.2.port'});
    final s = ObserverConfigService(auto);
    final r = await s.saveBroker(
      2,
      fields: {'url': 'mqtt://h', 'port': '1883'},
      enable: true,
      wasLive: false,
    );
    expect(r.ok, isFalse);
    expect(r.failedField, 'port');
    expect(
      setKeys(auto),
      isNot(contains('mqtt.broker.2.enabled')),
      reason: 'a failed field must never reach enabled=1 — slot stays safe',
    );
    auto.closeStream();
  });

  test('clearBroker sends the slot clear op', () async {
    final auto = _AutoConnector();
    final s = ObserverConfigService(auto);
    expect(await s.clearBroker(3), isTrue);
    expect(setKeys(auto), contains('mqtt.broker.3.clear'));
    auto.closeStream();
  });

  test(
    'getBroker re-reads one slot field-by-field, never the pool dump',
    () async {
      final auto = _AutoConnector();
      final s = ObserverConfigService(auto);
      final b = await s.getBroker(4);
      expect(b, isNotNull);
      expect(b!.slot, 4);
      final getKeys = auto.sent
          .where((f) => f.length > 2 && f[1] == ObserverConfigClient.opGet)
          .map((f) => utf8.decode(f.sublist(2, f.indexOf(0, 2))))
          .toList();
      expect(getKeys, contains('mqtt.broker.4.url'));
      expect(getKeys, contains('mqtt.broker.4.enabled'));
      expect(
        auto.sent.any((f) => f[1] == ObserverConfigClient.opBrokers),
        isFalse,
        reason: 'single-slot re-GET must not trigger the 84-frame pool dump',
      );
      auto.closeStream();
    },
  );

  // ---- #103: a slow-but-steady dump must outlast the fixed timeout ----
  test('getBrokers completes a dump that outlasts the per-frame timeout while '
      'frames keep arriving (re-armed inactivity watchdog) — #103', () async {
    svc.timeout = const Duration(milliseconds: 80);
    final future = svc.getBrokers();
    final frames = <Uint8List>[
      _brokersStart(2),
      _brokerKv(0, 'url', 'mqtt://a'),
      _brokerKv(0, 'enabled', '1'),
      _brokerKv(1, 'url', 'mqtt://b'),
      _brokerKv(1, 'enabled', '0'),
      _brokersEnd(),
    ];
    // Each 50ms gap is under the 80ms timeout, but the whole dump (~300ms)
    // far exceeds it: a fixed deadline kills it, a re-armed watchdog does not.
    for (final f in frames) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      c.inject(f);
    }
    final list = await future;
    expect(
      list,
      isNotNull,
      reason: 'a steadily-streaming dump must not time out (#103)',
    );
    expect(list!.length, 2);
    expect(list.map((b) => b.slot).toList(), [0, 1]);
  });
}
