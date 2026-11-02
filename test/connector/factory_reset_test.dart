// #1057 (epic #1054): factory reset of the connected radio.
//
// The radio drops the link before it formats, so success is only ever seen as
// the same device coming back with a new identity. These pin that the app data
// waits for that proof, and that every branch where it cannot tell keeps it.

import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/factory_reset_store.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late OffbandDatabase db;
  late MeshCoreConnector connector;
  late List<Uint8List> sent;

  const oldPrefix = 'aaaaaaaaaa';
  const newPrefix = 'bbbbbbbbbb';
  Uint8List keyOf(int fill) => Uint8List.fromList(List.filled(32, fill));

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
    db = OffbandDatabase(NativeDatabase.memory());
    BlobStore.overrideForTest(BlobStore(db));
    sent = [];
    connector = MeshCoreConnector()
      ..sendFrameOverrideForTest = sent.add
      ..transportIdentityForTest = 'dev-1'
      ..setSelfPublicKeyForTest(keyOf(0xaa))
      ..setFirmwareVerCodeForTest(14);
  });

  tearDown(() async {
    await db.close();
    BlobStore.clearTestOverride();
  });

  Future<void> seedOldRadio() async {
    await BlobStore.instance.write('contacts$oldPrefix', '[]');
    await PrefsManager.instance.setString('channels$oldPrefix', '[]');
  }

  Future<bool> oldRadioDataExists() async =>
      (await BlobStore.instance.keysWithPrefix(
        'contacts$oldPrefix',
      )).isNotEmpty ||
      PrefsManager.instance.getString('channels$oldPrefix') != null;

  test('the frame is the command then "reset"', () {
    expect(buildFactoryResetFrame(), [cmdFactoryReset, ...'reset'.codeUnits]);
    expect(cmdFactoryReset, 51);
  });

  group('refusals send nothing', () {
    test('not connected', () async {
      final refusal = await connector.factoryResetDevice(deleteAppData: true);

      expect(refusal, FactoryResetRefusal.notConnected);
      expect(sent, isEmpty);
      expect(FactoryResetStore().load(), isNull);
    });

    test('firmware older than ver code 7', () async {
      connector
        ..setConnectedForTest()
        ..setFirmwareVerCodeForTest(6);

      final refusal = await connector.factoryResetDevice(deleteAppData: true);

      expect(refusal, FactoryResetRefusal.unsupported);
      expect(sent, isEmpty);
      expect(FactoryResetStore().load(), isNull);
    });

    test('unknown firmware version', () async {
      connector
        ..setConnectedForTest()
        ..setFirmwareVerCodeForTest(null);

      expect(
        await connector.factoryResetDevice(deleteAppData: true),
        FactoryResetRefusal.unsupported,
      );
      expect(sent, isEmpty);
    });
  });

  test('a sent reset records the pending wipe, keeps the data, and ends the '
      'session', () async {
    await seedOldRadio();
    connector.setConnectedForTest();

    final refusal = await connector.factoryResetDevice(deleteAppData: true);

    expect(refusal, isNull);
    expect(sent.single, buildFactoryResetFrame());
    final pending = FactoryResetStore().load();
    expect(pending?.deviceId, 'dev-1');
    expect(pending?.radioPrefix, oldPrefix);
    expect(pending?.deleteAppData, isTrue);
    expect(await oldRadioDataExists(), isTrue);
    expect(connector.state, MeshCoreConnectionState.disconnected);
    expect(connector.factoryResetStatus, isNotNull);
  });

  group('the next connect settles it', () {
    Future<void> pend({bool deleteAppData = true}) => FactoryResetStore().save(
      PendingFactoryReset(
        deviceId: 'dev-1',
        radioPrefix: oldPrefix,
        deleteAppData: deleteAppData,
      ),
    );

    test('new identity, box ticked: old data deleted', () async {
      await seedOldRadio();
      await pend();
      connector.setSelfPublicKeyForTest(keyOf(0xbb));

      await connector.resolvePendingFactoryResetForTest();

      expect(await oldRadioDataExists(), isFalse);
      expect(FactoryResetStore().load(), isNull);
      expect(connector.factoryResetStatus, FactoryResetStatus.complete);
    });

    test('new identity, box unticked: old data kept', () async {
      await seedOldRadio();
      await pend(deleteAppData: false);
      connector.setSelfPublicKeyForTest(keyOf(0xbb));

      await connector.resolvePendingFactoryResetForTest();

      expect(await oldRadioDataExists(), isTrue);
      expect(FactoryResetStore().load(), isNull);
      expect(connector.factoryResetStatus, FactoryResetStatus.completeKept);
    });

    test('same identity: not reset, data kept', () async {
      await seedOldRadio();
      await pend();

      await connector.resolvePendingFactoryResetForTest();

      expect(await oldRadioDataExists(), isTrue);
      expect(FactoryResetStore().load(), isNull);
      expect(connector.factoryResetStatus, FactoryResetStatus.notReset);
    });

    test('a different device: nothing decided, data and record kept', () async {
      await seedOldRadio();
      await pend();
      connector
        ..transportIdentityForTest = 'dev-2'
        ..setSelfPublicKeyForTest(keyOf(0xbb));

      await connector.resolvePendingFactoryResetForTest();

      expect(await oldRadioDataExists(), isTrue);
      expect(FactoryResetStore().load(), isNotNull);
      expect(connector.factoryResetStatus, isNull);
    });

    test('the new radio\'s own data is never touched', () async {
      await pend();
      await BlobStore.instance.write('contacts$newPrefix', '[]');
      connector.setSelfPublicKeyForTest(keyOf(0xbb));

      await connector.resolvePendingFactoryResetForTest();

      expect(
        await BlobStore.instance.keysWithPrefix('contacts$newPrefix'),
        isNotEmpty,
      );
    });
  });
}
