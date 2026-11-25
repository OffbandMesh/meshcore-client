// #1170 (part of #1167): every contact the app drops, or asks the radio to
// delete, is logged by name, favorite flag, path and radio, so a contact that
// disappears can be traced to what took it. Logging only: which contacts are
// removed does not change.

import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/services/app_debug_log_service.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:meshcore_open/utils/app_logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _radioKey = Uint8List.fromList(List<int>.filled(32, 0xA1));
const _radio = 'a1a1a1a1a1';

Uint8List _u32(int v) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little);

Uint8List _contactFrame(int keyByte, String name, {List<int>? key}) {
  final b = BytesBuilder()
    ..addByte(respCodeContact)
    ..add(key ?? List<int>.filled(32, keyByte))
    ..addByte(advTypeChat)
    ..addByte(0)
    ..addByte(0xFF)
    ..add(List<int>.filled(64, 0))
    ..add(Uint8List(32)..setRange(0, name.length, utf8.encode(name)))
    ..add(_u32(1790000000))
    ..add(_u32(0))
    ..add(_u32(0))
    ..add(_u32(1790000000));
  return b.toBytes();
}

Uint8List _start(int declared) =>
    Uint8List.fromList([respCodeContactsStart, ..._u32(declared)]);

Uint8List get _end => Uint8List.fromList([respCodeEndOfContacts, ..._u32(0)]);

Contact _saved(int keyByte, String name, {bool favorite = false}) => Contact(
  publicKey: Uint8List.fromList(List<int>.filled(32, keyByte)),
  receivedName: name,
  type: advTypeChat,
  pathLength: -1,
  path: Uint8List(0),
  lastSeen: DateTime.utc(2026, 7, 1),
  flags: favorite ? contactFlagFavorite : 0,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late OffbandDatabase db;
  late MeshCoreConnector connector;
  late AppDebugLogService log;
  late List<Uint8List> sent;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
    db = OffbandDatabase(NativeDatabase.memory());
    BlobStore.overrideForTest(BlobStore(db));

    connector = MeshCoreConnector();
    connector.contactRecoverySettle = Duration.zero;
    connector.contactKeyCheckGap = Duration.zero;
    connector.contactKeyCheckTimeout = const Duration(milliseconds: 20);
    sent = [];
    connector.sendFrameOverrideForTest = sent.add;
    connector.setConnectedForTest();
    connector.setSelfPublicKeyForTest(_radioKey);
    log = AppDebugLogService()..setEnabled(true);
    appLogger.initialize(log, enabled: true);
    connector.setAppDebugLogServiceForTest(log);
  });

  tearDown(() async {
    BlobStore.clearTestOverride();
    await db.close();
  });

  List<String> lines(String fragment) => log.entries
      .map((e) => e.message)
      .where((m) => m.contains(fragment))
      .toList();

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 5));

  Future<void> answerStream(int declared, List<Uint8List> streamed) async {
    connector.handleFrameForTest(_start(declared));
    for (final f in streamed) {
      connector.handleFrameForTest(f);
    }
    connector.handleFrameForTest(_end);
    await settle();
  }

  void seed() {
    connector.contactsForTest
      ..add(_saved(0x11, 'Alpha'))
      ..add(_saved(0x22, 'Bravo', favorite: true))
      ..add(_saved(0x33, 'Charlie'));
  }

  test('a complete sync names each contact it drops', () async {
    seed();
    await connector.getContacts();
    await answerStream(1, [_contactFrame(0x11, 'Alpha')]);

    final removed = lines('Contact removed');
    expect(removed, hasLength(2));
    final bravo = removed.singleWhere((m) => m.contains('"Bravo"'));
    expect(bravo, contains('favorite'));
    expect(bravo, contains('complete sync did not include it'));
    expect(bravo, contains('key 22222222'));
    expect(bravo, contains('radio $_radio'));
    final charlie = removed.singleWhere((m) => m.contains('"Charlie"'));
    expect(charlie, isNot(contains('favorite')));
  });

  test('a contact the radio answers "not found" for is named', () async {
    // Two short syncs add up to the declared 3 without Bravo, so the app asks
    // the radio about Bravo by key.
    seed();
    connector.contactsForTest.add(_saved(0x44, 'Delta'));
    await connector.getContacts();
    await answerStream(3, [
      _contactFrame(0x11, 'Alpha'),
      _contactFrame(0x33, 'Charlie'),
    ]);
    await answerStream(3, [
      _contactFrame(0x11, 'Alpha'),
      _contactFrame(0x44, 'Delta'),
    ]);
    connector.handleFrameForTest(
      Uint8List.fromList([respCodeErr, errCodeNotFound]),
    );
    await settle();

    final removed = lines('Contact removed');
    expect(removed, hasLength(1));
    expect(removed.single, contains('"Bravo"'));
    expect(removed.single, contains('favorite'));
    expect(removed.single, contains('radio answered not found'));
  });

  test('choosing the radio list names each contact it drops', () async {
    seed();
    final alpha = [_contactFrame(0x11, 'Alpha')];
    await connector.getContacts();
    await answerStream(350, alpha);
    await answerStream(350, alpha);
    await answerStream(350, alpha);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(lines('Contact removed'), isEmpty, reason: 'nothing removed yet');

    await connector.resolveContactSyncUseRadio();

    final removed = lines('Contact removed');
    expect(removed, hasLength(2));
    expect(
      removed.singleWhere((m) => m.contains('"Bravo"')),
      allOf(contains('favorite'), contains('owner chose the radio list')),
    );
  });

  test('a user delete is named before the radio is told', () async {
    seed();
    final bravo = connector.contactsForTest[1];

    await connector.removeContact(bravo);

    final removed = lines('Contact removed');
    expect(removed, hasLength(1));
    expect(removed.single, contains('"Bravo"'));
    expect(removed.single, contains('favorite'));
    expect(removed.single, contains('user delete'));
    expect(sent.where((f) => f[0] == cmdRemoveContact), hasLength(1));
  });

  test('a contact holding the radio\'s own key is named', () async {
    connector.handleFrameForTest(
      _contactFrame(0, 'Myself', key: _radioKey.toList()),
    );
    await settle();

    final removed = lines('Contact removed');
    expect(removed, hasLength(1));
    expect(removed.single, contains('"Myself"'));
    expect(removed.single, contains("this radio's own key"));
    expect(removed.single, contains('radio $_radio'));
  });

  // #1028: the radio is the truth, so the app drops the contact it overwrote.
  test('the radio overwriting a contact is logged, and removes it here', () {
    seed();

    connector.handleFrameForTest([
      pushCodeContactDeleted,
      ...List.filled(32, 0x33),
    ]);

    final line = lines('Radio overwrote').single;
    expect(line, contains('"Charlie"'));
    expect(line, contains('key 33333333'));
    expect(line, contains('radio $_radio'));
    expect(
      connector.contactsForTest.map((c) => c.name),
      isNot(contains('Charlie')),
    );
  });

  test('the radio overwriting a favorite says so', () {
    seed();

    connector.handleFrameForTest([
      pushCodeContactDeleted,
      ...List.filled(32, 0x22),
    ]);

    expect(lines('Radio overwrote').single, contains('favorite'));
  });

  test('the radio overwriting a contact the app never had is logged', () {
    connector.handleFrameForTest([
      pushCodeContactDeleted,
      ...List.filled(32, 0x77),
    ]);

    expect(lines('Radio overwrote').single, contains('key 77777777'));
  });

  test('a full contact table on the radio is logged', () {
    connector.handleFrameForTest([pushCodeContactsFull]);
    connector.handleFrameForTest([pushCodeContactsFull]);
    connector.handleFrameForTest([pushCodeContactsFull]);

    expect(
      lines('contact table is full').single,
      contains('radio $_radio'),
      reason: 'the radio repeats this per node it cannot add: logged once',
    );
  });

  test('a radio whose key is not known yet is named "unknown"', () async {
    final unknown = MeshCoreConnector()
      ..sendFrameOverrideForTest = sent.add
      ..setConnectedForTest()
      ..setAppDebugLogServiceForTest(log)
      ..contactsForTest.add(_saved(0x11, 'Alpha'));

    await unknown.removeContact(unknown.contactsForTest.single);

    expect(lines('Contact removed').single, contains('radio unknown'));
  });

  test('the overwrite setting is logged when the radio reports it', () {
    connector.handleFrameForTest([
      respCodeAutoAddConfig,
      autoAddChatFlag | autoAddOverwriteOldestFlag,
      3,
    ]);
    connector.handleFrameForTest([respCodeAutoAddConfig, autoAddRepeaterFlag]);

    final settings = lines('auto-add');
    expect(settings, hasLength(2));
    expect(settings[0], contains('Radio $_radio'));
    expect(settings[0], contains('overwrite oldest on'));
    expect(settings[0], contains('chat on'));
    expect(settings[1], contains('overwrite oldest off'));
    expect(settings[1], contains('repeater on'));
  });
}
