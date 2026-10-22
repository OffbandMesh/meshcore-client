// #888: role-based CLI txt-type selection for remote CLI.
//
// A companion (chat) gets the 1.18 command type; a repeater/room server gets
// the universal CLI_DATA type. The user types the command, so the frame is a
// passthrough: the type byte changes, the command does not.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';

void main() {
  group('cliTxtTypeForContactType (#888)', () {
    test('a companion gets the 1.18 command type', () {
      expect(cliTxtTypeForContactType(advTypeChat), txtTypeCliCommand);
      expect(txtTypeCliCommand, 3);
    });

    test('a repeater keeps the universal CLI_DATA type', () {
      expect(cliTxtTypeForContactType(advTypeRepeater), txtTypeCliData);
    });

    test('a room server keeps the universal CLI_DATA type', () {
      expect(cliTxtTypeForContactType(advTypeRoom), txtTypeCliData);
    });
  });

  group('buildSendCliCommandFrame carries the chosen type (#888)', () {
    final pubKey = Uint8List.fromList(List<int>.generate(32, (i) => i));
    // [cmd][type][attempt][ts x4][pubKey x6][command][0]
    const int typeOffset = 1;
    const int commandOffset = 1 + 1 + 1 + 4 + 6;

    test(
      'defaults to CLI_DATA, so the existing repeater path is unchanged',
      () {
        final frame = buildSendCliCommandFrame(pubKey, 'get radio');
        expect(frame[typeOffset], txtTypeCliData);
      },
    );

    test('emits the command type when asked (companion path)', () {
      final frame = buildSendCliCommandFrame(
        pubKey,
        'get radio',
        txtType: txtTypeCliCommand,
      );
      expect(frame[typeOffset], txtTypeCliCommand);
    });

    test('the command is passed through byte-identical regardless of type', () {
      const command = '0A|set tx 22';
      final frame = buildSendCliCommandFrame(
        pubKey,
        command,
        txtType: txtTypeCliCommand,
      );
      final written = ascii.decode(
        frame.sublist(commandOffset, commandOffset + command.length),
      );
      expect(written, command);
    });
  });
}
