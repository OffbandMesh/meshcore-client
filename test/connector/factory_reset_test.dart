// #1057 (epic #1054): factory reset of the connected radio. With the box
// ticked, the radio's app data is deleted as soon as the reset is sent (#1118).

import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late OffbandDatabase db;
  late MeshCoreConnector connector;
  late List<Uint8List> sent;

  const radioPrefix = 'aaaaaaaaaa';
  const otherPrefix = 'bbbbbbbbbb';

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
    db = OffbandDatabase(NativeDatabase.memory());
    BlobStore.overrideForTest(BlobStore(db));
    sent = [];
    connector = MeshCoreConnector()
      ..sendFrameOverrideForTest = sent.add
      ..setSelfPublicKeyForTest(Uint8List.fromList(List.filled(32, 0xaa)))
      ..setFirmwareVerCodeForTest(14);
  });

  tearDown(() async {
    await db.close();
    BlobStore.clearTestOverride();
  });

  Future<void> seed(String prefix) async {
    await BlobStore.instance.write('contacts$prefix', '[]');
    await PrefsManager.instance.setString('channels$prefix', '[]');
  }

  Future<bool> dataExists(String prefix) async =>
      (await BlobStore.instance.keysWithPrefix('contacts$prefix')).isNotEmpty ||
      PrefsManager.instance.getString('channels$prefix') != null;

  test('the frame is the command then "reset"', () {
    expect(buildFactoryResetFrame(), [cmdFactoryReset, ...'reset'.codeUnits]);
    expect(cmdFactoryReset, 51);
  });

  test('not connected: nothing sent, nothing deleted', () async {
    await seed(radioPrefix);

    final refusal = await connector.factoryResetDevice(deleteAppData: true);

    expect(refusal, FactoryResetRefusal.notConnected);
    expect(sent, isEmpty);
    expect(await dataExists(radioPrefix), isTrue);
  });

  // Owner ruling: no FIRMWARE_VER_CODE gating.
  for (final verCode in [null, 0, 6]) {
    test('ver code $verCode is never consulted: the reset is sent', () async {
      connector
        ..setConnectedForTest()
        ..setFirmwareVerCodeForTest(verCode);

      final refusal = await connector.factoryResetDevice(deleteAppData: true);

      expect(refusal, isNull);
      expect(sent, [buildFactoryResetFrame()]);
    });
  }

  test('box ticked: the radio\'s app data is deleted on send, and only '
      'that radio\'s', () async {
    await seed(radioPrefix);
    await seed(otherPrefix);
    connector.setConnectedForTest();

    final refusal = await connector.factoryResetDevice(deleteAppData: true);

    expect(refusal, isNull);
    expect(sent.single, buildFactoryResetFrame());
    expect(connector.state, MeshCoreConnectionState.disconnected);
    expect(connector.factoryResetStatus, FactoryResetStatus.sentBle);
    expect(await dataExists(radioPrefix), isFalse);
    expect(await dataExists(otherPrefix), isTrue);
  });

  test('box unticked: the app data is kept', () async {
    await seed(radioPrefix);
    connector.setConnectedForTest();

    await connector.factoryResetDevice(deleteAppData: false);

    expect(sent.single, buildFactoryResetFrame());
    expect(await dataExists(radioPrefix), isTrue);
  });
}
