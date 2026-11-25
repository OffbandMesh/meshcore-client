// #1028: removal paths that had no test.
//
// A contact frame carrying the connected radio's own key is deleted from the
// radio (CMD_REMOVE_CONTACT) and its messages cleared. If the previous radio's
// key were still held as "self" after a switch, that delete would hit the next
// radio's contact for the previous radio, which an owner with two radios has.
// A user delete must also remove only the contact chosen.

import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/models/message.dart';
import 'package:meshcore_open/services/message_retry_service.dart';
import 'package:meshcore_open/services/path_history_service.dart';
import 'package:meshcore_open/services/storage_service.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

Uint8List _key(int b) => Uint8List.fromList(List<int>.filled(32, b));

String _hex(int b) => b.toRadixString(16).padLeft(2, '0') * 32;

Uint8List _u32(int v) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little);

Uint8List _contactFrame(int keyByte, String name) {
  final b = BytesBuilder()
    ..addByte(respCodeContact)
    ..add(_key(keyByte))
    ..addByte(advTypeChat)
    ..addByte(0)
    ..addByte(0xFF)
    ..add(List<int>.filled(64, 0))
    ..add(Uint8List(32)..setRange(0, name.length, name.codeUnits))
    ..add(_u32(1790000000))
    ..add(_u32(0))
    ..add(_u32(0))
    ..add(_u32(1790000000));
  return b.toBytes();
}

Future<void> _settle([int turns = 25]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

const _radioA = 0x0A;
const _radioB = 0x0B;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late OffbandDatabase db;
  late MeshCoreConnector c;
  late List<Uint8List> sent;

  Iterable<Uint8List> removalsOf(int keyByte) => sent.where(
    (f) =>
        f.length >= 33 &&
        f[0] == cmdRemoveContact &&
        f.sublist(1, 33).every((b) => b == keyByte),
  );
  bool holds(int keyByte) =>
      c.contactsForTest.any((x) => x.publicKeyHex == _hex(keyByte));

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
    db = OffbandDatabase(NativeDatabase.memory());
    BlobStore.overrideForTest(BlobStore(db));
    c = MeshCoreConnector();
    c.initialize(
      retryService: MessageRetryService(),
      pathHistoryService: PathHistoryService(StorageService()),
    );
    sent = [];
    c.sendFrameOverrideForTest = sent.add;
  });

  tearDown(() async {
    BlobStore.clearTestOverride();
    await db.close();
  });

  void becomeRadio(int keyByte) {
    c.setConnectedForTest();
    c.setSelfPublicKeyForTest(_key(keyByte));
  }

  Future<void> switchOverBluetooth() async {
    await c.disconnect(manual: true);
    try {
      await c
          .connect(BluetoothDevice.fromId('00:11:22:33:44:55'))
          .timeout(const Duration(seconds: 5));
    } catch (_) {}
    c.setConnectedForTest();
  }

  test("a radio's own key in its contact list is removed from it", () async {
    becomeRadio(_radioA);
    c.handleFrameForTest(_contactFrame(_radioA, 'Me'));
    await _settle();

    expect(removalsOf(_radioA), hasLength(1));
    expect(holds(_radioA), isFalse);
  });

  test('after a Bluetooth switch, the next radio keeps its contact for the '
      'previous radio', () async {
    becomeRadio(_radioA);
    await switchOverBluetooth();

    c.handleFrameForTest(_contactFrame(_radioA, 'Other radio'));
    await _settle();
    expect(
      removalsOf(_radioA),
      isEmpty,
      reason: "before B's SELF_INFO, A's key must no longer count as self",
    );

    c.setSelfPublicKeyForTest(_key(_radioB));
    c.handleFrameForTest(_contactFrame(_radioA, 'Other radio'));
    await _settle();

    expect(removalsOf(_radioA), isEmpty);
    expect(holds(_radioA), isTrue);
  });

  test('after a dropped link, the next radio keeps its contact for the '
      'previous radio', () async {
    becomeRadio(_radioA);
    // What the drop handler runs: the scope keys, including the self key, go.
    c.clearStorageScopeKeysForTest();

    c.handleFrameForTest(_contactFrame(_radioA, 'Other radio'));
    await _settle();

    expect(removalsOf(_radioA), isEmpty);
    expect(holds(_radioA), isTrue);
  });

  test('a user delete removes only the contact chosen', () async {
    becomeRadio(_radioB);
    for (final (k, n) in [(0x11, 'Alpha'), (0x22, 'Bravo'), (0x33, 'Delta')]) {
      c.handleFrameForTest(_contactFrame(k, n));
    }
    await _settle();
    c.conversationsForTest[_hex(0x11)] = [
      Message(
        senderKey: _key(0x11),
        text: 'keep me',
        timestamp: DateTime.utc(2026, 11, 24),
        isOutgoing: false,
      ),
    ];
    final bravo = c.contactsForTest.firstWhere((x) => x.name == 'Bravo');

    await c.removeContact(bravo);
    await _settle();

    expect(sent.where((f) => f.isNotEmpty && f[0] == cmdRemoveContact), [
      ...removalsOf(0x22),
    ]);
    expect(removalsOf(0x22), hasLength(1));
    expect(holds(0x22), isFalse);
    expect(holds(0x11), isTrue);
    expect(holds(0x33), isTrue);
    expect(c.conversationsForTest[_hex(0x11)], isNotEmpty);
  });
}
