// #999: remote CLI is a companion-only feature, and the chat-screen entry point
// gates on Contact.isCompanion. These pin that only a chat node reads as a
// companion - a repeater, room server or sensor must not, or the CLI-console
// action would appear where it does not belong.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/models/contact.dart';

Contact _of(int type) => Contact(
  publicKey: Uint8List.fromList(List<int>.generate(32, (i) => i)),
  receivedName: 'X',
  type: type,
  pathLength: 0,
  path: Uint8List(0),
  lastSeen: DateTime.fromMillisecondsSinceEpoch(0),
);

void main() {
  test('a chat node is a companion', () {
    expect(_of(advTypeChat).isCompanion, isTrue);
  });

  test('a repeater, room server or sensor is not a companion', () {
    expect(_of(advTypeRepeater).isCompanion, isFalse);
    expect(_of(advTypeRoom).isCompanion, isFalse);
    expect(_of(advTypeSensor).isCompanion, isFalse);
  });
}
