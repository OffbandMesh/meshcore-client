import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/cli_command_codec.dart';

void main() {
  group('buildRunCliCommandFrame', () {
    test('plain command', () {
      final f = buildRunCliCommandFrame('get radio');
      expect(f[0], cmdRunCliCommand);
      expect(ascii.decode(f.sublist(1)), 'get radio');
    });

    test('with correlation prefix', () {
      final f = buildRunCliCommandFrame('get radio', prefix: '0A|');
      expect(ascii.decode(f.sublist(1)), '0A|get radio');
    });

    test('rejects an empty command', () {
      expect(() => buildRunCliCommandFrame(''), throwsArgumentError);
      expect(() => buildRunCliCommandFrame('   '), throwsArgumentError);
    });

    test('rejects a command shorter than the firmware minimum', () {
      // Firmware requires frame len >= 3, i.e. at least 2 command bytes.
      expect(() => buildRunCliCommandFrame('b'), throwsArgumentError);
    });

    test('rejects a malformed prefix', () {
      expect(
        () => buildRunCliCommandFrame('ver', prefix: '0A'),
        throwsArgumentError,
      );
      expect(
        () => buildRunCliCommandFrame('ver', prefix: 'ABCD|'),
        throwsArgumentError,
      );
    });
  });

  group('parseCliReply', () {
    Uint8List reply(String text) =>
        Uint8List.fromList([respCodeCliReply, ...ascii.encode(text)]);

    test('reply with reflected prefix', () {
      final r = parseCliReply(reply('0A|> 910.525,62.5,7,5'));
      expect(r, isNotNull);
      expect(r!.prefix, '0A|');
      expect(r.text, '> 910.525,62.5,7,5');
    });

    test('reply without prefix', () {
      final r = parseCliReply(reply('Unknown command'));
      expect(r!.prefix, isNull);
      expect(r.text, 'Unknown command');
    });

    test('empty reply text', () {
      final r = parseCliReply(Uint8List.fromList([respCodeCliReply]));
      expect(r!.text, '');
      expect(r.prefix, isNull);
    });

    test('wrong frame code returns null', () {
      final r = parseCliReply(Uint8List.fromList([13, 65, 66]));
      expect(r, isNull);
    });

    test('a short reply whose third byte is not | is all text', () {
      final r = parseCliReply(reply('ok'));
      expect(r!.prefix, isNull);
      expect(r.text, 'ok');
    });

    test('device truncation bound is judged on the RAW payload, prefix'
        ' included', () {
      // A real truncated reply: total payload exactly 165 bytes, of which
      // 3 are the reflected prefix (post-strip text is only 162).
      final r = parseCliReply(reply('0A|${'x' * (maxCliReplyPayload - 3)}'));
      expect(r!.payloadLength, maxCliReplyPayload);
      expect(r.atReplyBound, isTrue);
      final short = parseCliReply(reply('0A|ok'));
      expect(short!.atReplyBound, isFalse);
    });

    test('non-ASCII commands are rejected at build time', () {
      expect(
        () => buildRunCliCommandFrame('set name Ωmega'),
        throwsArgumentError,
      );
    });

    test('non-ascii bytes decode leniently rather than throwing', () {
      final r = parseCliReply(
        Uint8List.fromList([respCodeCliReply, 0x4F, 0x4B, 0xFF]),
      );
      expect(r!.text.startsWith('OK'), isTrue);
    });
  });
}
