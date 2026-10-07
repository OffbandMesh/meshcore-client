// Epic #813 T3: connector wiring for region discovery + flood-scope.
// Exercises the real dispatch/correlation via the test seams
// (setConnectedForTest / sendFrameOverrideForTest / handleFrameForTest).
// No key material here is real.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

Uint8List _u32le(int v) {
  final b = Uint8List(4);
  ByteData.sublistView(b).setUint32(0, v, Endian.little);
  return b;
}

Uint8List _padName(String name, int len) {
  final b = Uint8List(len);
  for (var i = 0; i < name.length && i < len - 1; i++) {
    b[i] = name.codeUnitAt(i);
  }
  return b;
}

// Build the 0x8C reply a repeater would elicit for a given outgoing request,
// echoing the request's tag (bytes 33..37 of the CMD_SEND_ANON_REQ frame).
Uint8List _regionsReplyFor(
  Uint8List req, {
  required int clock,
  required String csv,
}) {
  final tag = ByteData.sublistView(req, 33, 37).getUint32(0, Endian.little);
  final b = BytesBuilder()
    ..addByte(pushCodeBinaryResponse)
    ..addByte(0)
    ..add(_u32le(tag))
    ..add(_u32le(clock))
    ..add(Uint8List.fromList([...csv.codeUnits, 0]));
  return b.toBytes();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MeshCoreConnector connector;
  final pub = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
    connector = MeshCoreConnector();
    connector.setConnectedForTest();
    connector.setFirmwareVerCodeForTest(22);
  });

  group('discoverRegions', () {
    test(
      'sends the anon regions request and returns the parsed reply',
      () async {
        Uint8List? sent;
        connector.sendFrameOverrideForTest = (data) {
          sent = data;
          connector.handleFrameForTest(
            _regionsReplyFor(data, clock: 0x01020304, csv: 'oki,test,*'),
          );
        };
        final reply = await connector.discoverRegions(repeaterPubKey: pub);
        expect(sent, isNotNull);
        expect(sent![0], cmdSendAnonReq);
        expect(sent![37], anonReqTypeRegions);
        expect(reply, isNotNull);
        expect(reply!.regionNames, ['oki', 'test', '*']);
        expect(reply.clock, 0x01020304);
      },
    );

    test('returns null on timeout when no reply arrives', () async {
      connector.sendFrameOverrideForTest = (_) {};
      final reply = await connector.discoverRegions(
        repeaterPubKey: pub,
        timeout: const Duration(milliseconds: 50),
      );
      expect(reply, isNull);
    });

    test(
      'a 0x8C with a non-matching tag never satisfies the request',
      () async {
        connector.sendFrameOverrideForTest = (_) {
          final b = BytesBuilder()
            ..addByte(pushCodeBinaryResponse)
            ..addByte(0)
            ..add(_u32le(0xFFFFFFFF))
            ..add(_u32le(1))
            ..add(Uint8List.fromList([...'zzz'.codeUnits, 0]));
          connector.handleFrameForTest(b.toBytes());
        };
        final reply = await connector.discoverRegions(
          repeaterPubKey: pub,
          timeout: const Duration(milliseconds: 80),
        );
        expect(reply, isNull);
      },
    );

    test('refuses when firmware does not support region scope', () async {
      connector.setFirmwareVerCodeForTest(7);
      expect(connector.supportsRegionScope, isFalse);
      await expectLater(
        connector.discoverRegions(repeaterPubKey: pub),
        throwsStateError,
      );
    });
  });

  group('send-scope setters', () {
    test('setChannelSendScope emits [54][0][key16]', () async {
      Uint8List? sent;
      connector.sendFrameOverrideForTest = (d) => sent = d;
      final key = Uint8List.fromList(List<int>.generate(16, (i) => 0xA0 + i));
      await connector.setChannelSendScope(key);
      expect(sent, isNotNull);
      expect(sent![0], cmdSetFloodScopeKey);
      expect(sent![1], floodScopeSubSetKey);
      expect(sent!.sublist(2), key);
    });

    test('clearSendScope emits [54][0]', () async {
      Uint8List? sent;
      connector.sendFrameOverrideForTest = (d) => sent = d;
      await connector.clearSendScope();
      expect(sent, [cmdSetFloodScopeKey, floodScopeSubSetKey]);
    });

    test('setChannelSendScope refuses when unsupported', () async {
      connector.setFirmwareVerCodeForTest(7);
      await expectLater(
        connector.setChannelSendScope(Uint8List(16)),
        throwsStateError,
      );
    });
  });

  group('default flood scope', () {
    test('getDefaultFloodScope returns the parsed RESP 28', () async {
      connector.sendFrameOverrideForTest = (_) {
        final b = BytesBuilder()
          ..addByte(respCodeDefaultFloodScope)
          ..add(_padName('oki', 31))
          ..add(Uint8List.fromList(List<int>.generate(16, (i) => i)));
        connector.handleFrameForTest(b.toBytes());
      };
      final scope = await connector.getDefaultFloodScope();
      expect(scope, isNotNull);
      expect(scope!.name, 'oki');
      expect(scope.isSet, isTrue);
    });

    test('setDefaultFloodScope emits [63][name31][key16]', () async {
      Uint8List? sent;
      connector.sendFrameOverrideForTest = (d) => sent = d;
      await connector.setDefaultFloodScope('oki', Uint8List(16));
      expect(sent, isNotNull);
      expect(sent![0], cmdSetDefaultFloodScope);
      expect(sent!.length, 1 + 31 + 16);
    });

    test('coalesces concurrent calls onto one in-flight query', () async {
      var sends = 0;
      connector.sendFrameOverrideForTest = (_) {
        sends++;
        final b = BytesBuilder()
          ..addByte(respCodeDefaultFloodScope)
          ..add(_padName('oki', 31))
          ..add(Uint8List(16));
        connector.handleFrameForTest(b.toBytes());
      };
      final f1 = connector.getDefaultFloodScope();
      final f2 = connector.getDefaultFloodScope();
      final r1 = await f1;
      final r2 = await f2;
      expect(sends, 1); // second caller did not emit a second frame
      expect(r1!.name, 'oki');
      expect(r2!.name, 'oki');
    });
  });
}
