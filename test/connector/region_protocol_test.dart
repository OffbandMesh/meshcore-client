import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';

// Wire contract verified against firmware source:
//  - companion MyMesh.cpp:3114-3144 (CMD_SEND_ANON_REQ, non-contact 13+),
//    3512-3548 (CMD_SET_FLOOD_SCOPE_KEY 54, CMD_SET/GET_DEFAULT_FLOOD_SCOPE
//    63/64, RESP_CODE_DEFAULT_FLOOD_SCOPE 28), 1201-1211 (0x8C envelope).
//  - simple_repeater MyMesh.cpp:586-607, 150-163 (anon regions req/reply).

Uint8List _key16(int seed) =>
    Uint8List.fromList(List<int>.generate(16, (i) => (seed + i) & 0xFF));

void main() {
  group('buildAnonRegionsRequestFrame', () {
    test('[57][pubkey32][ts4 LE][0x01][reply_path_len=0]', () {
      final pub = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
      final frame = buildAnonRegionsRequestFrame(pub, timestamp: 0x11223344);
      expect(frame.length, 1 + 32 + 4 + 1 + 1);
      expect(frame[0], cmdSendAnonReq);
      expect(frame.sublist(1, 33), pub);
      expect(frame.sublist(33, 37), [0x44, 0x33, 0x22, 0x11]); // LE timestamp
      expect(frame[37], anonReqTypeRegions);
      expect(frame[38], 0); // zero reply-path = zero-hop direct
    });
  });

  group('flood-scope key frames', () {
    test('set: [54][0][key16]', () {
      final frame = buildSetFloodScopeKeyFrame(_key16(0xA0));
      expect(frame.length, 2 + 16);
      expect(frame[0], cmdSetFloodScopeKey);
      expect(frame[1], 0);
      expect(frame.sublist(2), _key16(0xA0));
    });

    test('clear override to node default: [54][0]', () {
      expect(buildClearFloodScopeFrame(), [cmdSetFloodScopeKey, 0]);
    });

    test('force unscoped (ver 12+): [54][1]', () {
      expect(buildFloodScopeUnscopedFrame(), [cmdSetFloodScopeKey, 1]);
    });
  });

  group('default flood scope', () {
    test('set: [63][name:31 NUL-padded][key:16]', () {
      final frame = buildSetDefaultFloodScopeFrame('oki', _key16(0x10));
      expect(frame.length, 1 + 31 + 16);
      expect(frame[0], cmdSetDefaultFloodScope);
      expect(frame.sublist(1, 4), 'oki'.codeUnits);
      expect(frame[4], 0); // NUL terminator
      expect(frame.sublist(32, 48), _key16(0x10));
    });

    test('clear: [63]', () {
      expect(buildClearDefaultFloodScopeFrame(), [cmdSetDefaultFloodScope]);
    });

    test('get: [64]', () {
      expect(buildGetDefaultFloodScopeFrame(), [cmdGetDefaultFloodScope]);
    });

    test('parse RESP 28 with a set scope', () {
      final f = BytesBuilder()
        ..addByte(respCodeDefaultFloodScope)
        ..add(_padName('oki', 31))
        ..add(_key16(0x10));
      final scope = parseDefaultFloodScopeReply(f.toBytes());
      expect(scope, isNotNull);
      expect(scope!.name, 'oki');
      expect(scope.key, _key16(0x10));
      expect(scope.isSet, isTrue);
    });

    test('parse bare RESP 28 as no-default', () {
      final scope = parseDefaultFloodScopeReply(
        Uint8List.fromList([respCodeDefaultFloodScope]),
      );
      expect(scope, isNotNull);
      expect(scope!.isSet, isFalse);
    });

    test('parse returns null for a non-28 frame', () {
      expect(
        parseDefaultFloodScopeReply(Uint8List.fromList([respCodeOk])),
        isNull,
      );
    });
  });

  group('parseRegionsReply (0x8C envelope)', () {
    Uint8List reply(int tag, int clock, String csv) {
      final b = BytesBuilder()
        ..addByte(pushCodeBinaryResponse)
        ..addByte(0) // reserved
        ..add(_u32le(tag))
        ..add(_u32le(clock))
        ..add(Uint8List.fromList([...csv.codeUnits, 0]));
      return b.toBytes();
    }

    test('extracts tag, clock, and comma-split names', () {
      final r = parseRegionsReply(reply(0xDEADBEEF, 0x01020304, 'oki,test,*'));
      expect(r, isNotNull);
      expect(r!.tag, 0xDEADBEEF);
      expect(r.clock, 0x01020304);
      expect(r.regionNames, ['oki', 'test', '*']);
    });

    test('empty CSV yields no names (not a parse error)', () {
      final r = parseRegionsReply(reply(1, 2, ''));
      expect(r, isNotNull);
      expect(r!.regionNames, isEmpty);
    });

    test('null for a short or non-0x8C frame', () {
      expect(
        parseRegionsReply(Uint8List.fromList([pushCodeBinaryResponse, 0])),
        isNull,
      );
      expect(
        parseRegionsReply(
          Uint8List.fromList([respCodeOk, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        ),
        isNull,
      );
    });
  });

  group('firmwareSupportsRegionScope', () {
    test('floor is FIRMWARE_VER_CODE 13', () {
      expect(firmwareSupportsRegionScope(null), isFalse);
      expect(firmwareSupportsRegionScope(7), isFalse);
      expect(firmwareSupportsRegionScope(12), isFalse);
      expect(firmwareSupportsRegionScope(13), isTrue);
      expect(firmwareSupportsRegionScope(22), isTrue);
    });
  });
}

Uint8List _u32le(int v) {
  final b = Uint8List(4);
  ByteData.sublistView(b).setUint32(0, v, Endian.little);
  return b;
}

Uint8List _padName(String name, int len) {
  final b = Uint8List(len);
  final bytes = name.codeUnits;
  for (var i = 0; i < bytes.length && i < len - 1; i++) {
    b[i] = bytes[i];
  }
  return b;
}
