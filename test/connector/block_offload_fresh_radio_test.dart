import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/services/block_service.dart';
import 'package:meshcore_open/services/message_retry_service.dart';
import 'package:meshcore_open/services/path_history_service.dart';
import 'package:meshcore_open/services/storage_service.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

// #471 Option A: connecting to a radio that reports an EMPTY block list must not
// offload the client's block list onto it (that made fresh/erased radios come
// up pre-blocked). A radio that already holds blocks still unions normally.
void main() {
  final clientKey = 'cc' * 32; // 32-byte key, all 0xcc
  final extraKey = 'ee' * 32;

  late OffbandDatabase db;
  late MeshCoreConnector connector;
  late BlockService block;
  late List<Uint8List> sent;

  // Block-list dump framing: START [0xC2 0x03 0xFF count], KEY [0xC2 0x03 idx key32], END [0xC2 0x03 0xFE].
  Uint8List start(int count) =>
      Uint8List.fromList([cmdOffbandBlock, offbandBlockList, 0xFF, count]);
  Uint8List key(int idx, int keyByte) => Uint8List.fromList([
    cmdOffbandBlock,
    offbandBlockList,
    idx,
    ...List<int>.filled(32, keyByte),
  ]);
  Uint8List end() =>
      Uint8List.fromList([cmdOffbandBlock, offbandBlockList, 0xFE]);

  List<Uint8List> blockAddFrames() => sent
      .where(
        (f) =>
            f.length > 1 && f[0] == cmdOffbandBlock && f[1] == offbandBlockAdd,
      )
      .toList();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
    db = OffbandDatabase(NativeDatabase.memory());
    BlobStore.overrideForTest(BlobStore(db));

    connector = MeshCoreConnector();
    block = BlockService();
    connector.initialize(
      retryService: MessageRetryService(),
      pathHistoryService: PathHistoryService(StorageService()),
      blockService: block,
    );
    sent = [];
    connector.sendFrameOverrideForTest = sent.add;
    connector.setConnectedForTest();
    // Make the radio block-capable so a push WOULD fire but for the guard.
    connector.setFirmwareVerCodeForTest(15);
    connector.setOffbandCapsForTest(offbandCapBlock);
  });

  tearDown(() async {
    BlobStore.clearTestOverride();
    await db.close();
  });

  test(
    'a radio reporting no blocks is NOT offloaded the client list',
    () async {
      await block.importKeys({clientKey}); // client has a block
      sent.clear();

      connector.handleFrameForTest(start(0));
      connector.handleFrameForTest(end());
      await Future<void>.delayed(Duration.zero);

      expect(
        blockAddFrames(),
        isEmpty,
        reason: 'a blank radio must not inherit the client block list',
      );
    },
  );

  test(
    'a radio that already holds blocks still unions the client extras',
    () async {
      await block.importKeys({clientKey, extraKey});
      sent.clear();

      // Radio holds clientKey (0xcc) already, but not extraKey (0xee).
      connector.handleFrameForTest(start(1));
      connector.handleFrameForTest(key(0, 0xcc));
      connector.handleFrameForTest(end());
      await Future<void>.delayed(Duration.zero);

      final pushed = blockAddFrames();
      expect(pushed.length, 1, reason: 'only the extra block is offloaded');
      // The pushed key is extraKey (0xee...), not the one the radio already had.
      expect(pushed.single.sublist(2), List<int>.filled(32, 0xee));
    },
  );
}
