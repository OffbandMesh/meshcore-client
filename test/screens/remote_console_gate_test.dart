// #999 reopen, #1157: the companion "CLI console" entry is offered only when
// BOTH the target is a companion AND the connected radio sends remote CLI
// (stock 1.18+, or Offband advertising 0x07; the gate itself is pinned in
// test/connector/cli_advert_gate_test.dart). A radio that cannot send a type-3
// command only produces failures, so it is not offered there.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
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

void main() {
  test('a companion, on a radio that sends remote CLI, is offered it', () {
    expect(
      DeviceCliScreen.offersRemoteConsole(
        contact: _contact(advTypeChat),
        radioSupportsRemoteCli: true,
      ),
      isTrue,
    );
  });

  test('no console when the connected radio cannot send remote CLI', () {
    expect(
      DeviceCliScreen.offersRemoteConsole(
        contact: _contact(advTypeChat),
        radioSupportsRemoteCli: false,
      ),
      isFalse,
    );
  });

  test('no console for a repeater or room server, even on a capable radio', () {
    for (final type in [advTypeRepeater, advTypeRoom, advTypeSensor]) {
      expect(
        DeviceCliScreen.offersRemoteConsole(
          contact: _contact(type),
          radioSupportsRemoteCli: true,
        ),
        isFalse,
        reason: 'type $type has its own CLI via the repeater hub',
      );
    }
  });
}
