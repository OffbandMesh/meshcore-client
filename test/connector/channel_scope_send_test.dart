// Epic #815 T C3: per-send region scoping around a channel send.
// Drives the scoping helper via its test seam, capturing the frame sequence.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Known vector: first 16 bytes of SHA256("#oki").
final _okiKey = Uint8List.fromList([
  0x59, 0x9f, 0xe2, 0x54, 0x60, 0x02, 0x70, 0x9f, //
  0xa4, 0x93, 0xb1, 0x5d, 0xe5, 0x8b, 0xdd, 0x0d,
]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MeshCoreConnector connector;
  final frame = Uint8List.fromList([cmdSendChannelTxtMsg, 0, 1, 2, 3]);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
    connector = MeshCoreConnector();
    connector.setConnectedForTest();
    connector.setFirmwareVerCodeForTest(22);
    connector.channelRegionScopeStoreForTest.setPublicKeyHex =
        'aabbccddee0011223344';
  });

  test('an unscoped channel sends the frame alone', () async {
    final sent = <Uint8List>[];
    connector.sendFrameOverrideForTest = sent.add;
    await connector.sendChannelFrameScopedForTest(0, frame);
    expect(sent, hasLength(1));
    expect(sent.single, frame);
  });

  test('a scoped channel sets the key, sends, then clears', () async {
    await connector.channelRegionScopeStoreForTest.setScope(0, 'oki');
    final sent = <Uint8List>[];
    connector.sendFrameOverrideForTest = sent.add;
    await connector.sendChannelFrameScopedForTest(0, frame);
    expect(sent, hasLength(3));
    // set scope: [54, 0, key16]
    expect(sent[0][0], cmdSetFloodScopeKey);
    expect(sent[0][1], floodScopeSubSetKey);
    expect(sent[0].sublist(2), _okiKey);
    // the message
    expect(sent[1], frame);
    // clear scope: [54, 0]
    expect(sent[2], [cmdSetFloodScopeKey, floodScopeSubSetKey]);
  });

  test(
    'a scoped channel on unsupported firmware is blocked, nothing sent',
    () async {
      await connector.channelRegionScopeStoreForTest.setScope(0, 'oki');
      connector.setFirmwareVerCodeForTest(7);
      final sent = <Uint8List>[];
      connector.sendFrameOverrideForTest = sent.add;
      await expectLater(
        connector.sendChannelFrameScopedForTest(0, frame),
        throwsStateError,
      );
      expect(sent, isEmpty);
    },
  );

  test('a failed set-scope still attempts a clear (no scope leak)', () async {
    await connector.channelRegionScopeStoreForTest.setScope(0, 'oki');
    var calls = 0;
    connector.sendFrameOverrideForTest = (_) {
      calls++;
      if (calls == 1) throw Exception('lost ack on set-scope');
    };
    await expectLater(
      connector.sendChannelFrameScopedForTest(0, frame),
      throwsA(isA<Exception>()),
    );
    // call 1 = set-scope (threw); call 2 = clear-scope run from the finally.
    expect(calls, 2);
  });
}
