import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #762: asking the radio for one contact by key. "Not found" is the only
/// proof a contact is gone from the radio, so it must never be inferred from
/// an ERR that something else could own.
Uint8List _key(int b) => Uint8List.fromList(List<int>.filled(32, b));

Uint8List _contactFrame(int keyByte, String name) {
  final b = BytesBuilder()
    ..addByte(respCodeContact)
    ..add(_key(keyByte))
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

Uint8List _u32(int v) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little);

Uint8List _err(int code) => Uint8List.fromList([respCodeErr, code]);

void main() {
  late OffbandDatabase db;
  late MeshCoreConnector connector;
  late List<Uint8List> sent;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
    db = OffbandDatabase(NativeDatabase.memory());
    BlobStore.overrideForTest(BlobStore(db));

    connector = MeshCoreConnector();
    connector.contactsForTest.clear();
    connector.contactKeyCheckTimeout = const Duration(milliseconds: 50);
    sent = [];
    connector.sendFrameOverrideForTest = sent.add;
    connector.setConnectedForTest();
  });

  tearDown(() async {
    BlobStore.clearTestOverride();
    await db.close();
  });

  int byKeyRequests() =>
      sent.where((f) => f.isNotEmpty && f[0] == cmdGetContactByKey).length;

  test('a CONTACT for the key means it is on the radio', () async {
    final result = connector.checkContactOnRadio(_key(0x11));
    expect(byKeyRequests(), 1);
    connector.handleFrameForTest(_contactFrame(0x11, 'Alpha'));
    expect(await result, ContactKeyCheckResult.onRadio);
  });

  test('NOT_FOUND with nothing else in flight means gone', () async {
    final result = connector.checkContactOnRadio(_key(0x11));
    connector.handleFrameForTest(_err(errCodeNotFound));
    expect(await result, ContactKeyCheckResult.notFound);
  });

  test('a CONTACT for another key does not answer the check', () async {
    final result = connector.checkContactOnRadio(_key(0x11));
    connector.handleFrameForTest(_contactFrame(0x22, 'Bravo'));
    expect(await result, ContactKeyCheckResult.unresolved);
  });

  test('BAD_STATE is never read as not found', () async {
    final result = connector.checkContactOnRadio(_key(0x11));
    connector.handleFrameForTest(_err(4));
    expect(await result, ContactKeyCheckResult.unresolved);
  });

  test('no reply times out as unresolved', () async {
    expect(
      await connector.checkContactOnRadio(_key(0x11)),
      ContactKeyCheckResult.unresolved,
    );
  });

  test('NOT_FOUND after another by-key request is not trusted', () async {
    final result = connector.checkContactOnRadio(_key(0x11));
    await connector.getContactByKey(_key(0x22));
    connector.handleFrameForTest(_err(errCodeNotFound));
    expect(await result, ContactKeyCheckResult.unresolved);
  });

  test('NOT_FOUND during a contact stream is not trusted', () async {
    await connector.getContacts();
    final result = connector.checkContactOnRadio(_key(0x11));
    connector.handleFrameForTest(_err(errCodeNotFound));
    expect(await result, ContactKeyCheckResult.unresolved);
  });

  test('a second check while one is pending sends nothing', () async {
    final first = connector.checkContactOnRadio(_key(0x11));
    expect(
      await connector.checkContactOnRadio(_key(0x22)),
      ContactKeyCheckResult.unresolved,
    );
    expect(byKeyRequests(), 1);
    connector.handleFrameForTest(_contactFrame(0x11, 'Alpha'));
    expect(await first, ContactKeyCheckResult.onRadio);
  });

  test('a send failure is unresolved and frees the next check', () async {
    connector.sendFrameOverrideForTest = (_) => throw Exception('usb gone');
    expect(
      await connector.checkContactOnRadio(_key(0x11)),
      ContactKeyCheckResult.unresolved,
    );
    connector.sendFrameOverrideForTest = sent.add;
    final next = connector.checkContactOnRadio(_key(0x22));
    connector.handleFrameForTest(_contactFrame(0x22, 'Bravo'));
    expect(await next, ContactKeyCheckResult.onRadio);
  });

  test('a disconnect mid-check ends it unresolved', () async {
    final result = connector.checkContactOnRadio(_key(0x11));
    connector.resetConnectionHandshakeStateForTest();
    expect(await result, ContactKeyCheckResult.unresolved);
  });
}
