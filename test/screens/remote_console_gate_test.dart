// #999 reopen: the companion "CLI console" entry is offered only when BOTH the
// target is a companion AND the connected radio speaks the 1.18 CLI. A
// pre-1.18 radio (stock 1.17, or Offband before the absorb) refuses a type-3
// send, so offering the console there only produces failures.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/device_population.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/screens/device_cli_screen.dart';

Contact _contact(int type) => Contact(
  publicKey: Uint8List.fromList(List<int>.generate(32, (i) => i)),
  receivedName: 'X',
  type: type,
  pathLength: 0,
  path: Uint8List(0),
  lastSeen: DateTime.fromMillisecondsSinceEpoch(0),
);

Classification _radio(DevicePopulation population) =>
    Classification(population: population, conflict: false, evidence: 'test');

void main() {
  test('a companion on a 1.18 radio is offered the console', () {
    expect(
      DeviceCliScreen.offersRemoteConsole(
        contact: _contact(advTypeChat),
        classification: _radio(DevicePopulation.stockModern),
      ),
      isTrue,
    );
  });

  test('no console when the connected radio is pre-1.18 or Offband', () {
    for (final population in [
      DevicePopulation.stockLegacy,
      DevicePopulation.offband,
    ]) {
      expect(
        DeviceCliScreen.offersRemoteConsole(
          contact: _contact(advTypeChat),
          classification: _radio(population),
        ),
        isFalse,
        reason: '$population cannot send a type-3 command',
      );
    }
  });

  test('no console when the radio is not classified (disconnected)', () {
    expect(
      DeviceCliScreen.offersRemoteConsole(
        contact: _contact(advTypeChat),
        classification: null,
      ),
      isFalse,
    );
  });

  test('no console for a repeater or room server, even on a 1.18 radio', () {
    for (final type in [advTypeRepeater, advTypeRoom, advTypeSensor]) {
      expect(
        DeviceCliScreen.offersRemoteConsole(
          contact: _contact(type),
          classification: _radio(DevicePopulation.stockModern),
        ),
        isFalse,
        reason: 'type $type has its own CLI via the repeater hub',
      );
    }
  });
}
