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

Uint8List _respText(int sub, String text) => Uint8List.fromList([
  ObserverConfigClient.respConfig,
  sub,
  ...utf8.encode(text),
  0,
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
}
