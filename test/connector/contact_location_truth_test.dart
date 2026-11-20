// #1166: a node's location is whatever the radio last fed for it. A value the
// app stored never beats it, 0,0 means unknown, and an advert without a
// location withdraws the old one.

import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _key = Uint8List.fromList(List<int>.generate(32, (i) => 0x5A + i));

const _lat = 12345670;
const _lon = -23456780;

List<int> _i32(int v) =>
    (ByteData(4)..setInt32(0, v, Endian.little)).buffer.asUint8List();

List<int> _u32(int v) =>
    (ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List();

/// A raw advert as the radio forwards it (0x88). [lat] null leaves the
/// location flag off; 0,0 sets the flag with zeros, as a repeater with no
/// location configured does.
List<int> _rxAdvert(int ts, {int? lat, int? lon, int type = advTypeRepeater}) =>
    [
      0x88, 0, 0,
      (payloadTypeADVERT << 2) | 0x01, // flood
      0, // no path
      ..._key,
      ..._u32(ts),
      ...List<int>.filled(64, 0),
      type | (lat != null ? 0x10 : 0) | 0x80,
      if (lat != null) ..._i32(lat),
      if (lon != null) ..._i32(lon),
      ...'NODE'.codeUnits,
    ];

/// The radio's own record for the node: a contact sync frame, or the
/// new-advert push, which has the same layout.
List<int> _radioRecord(
  int ts, {
  int lat = 0,
  int lon = 0,
  int code = respCodeContact,
}) => [
  code,
  ..._key,
  advTypeRepeater,
  0,
  0,
  ...List<int>.filled(maxPathSize, 0),
  ...'NODE'.codeUnits,
  ...List<int>.filled(maxNameSize - 4, 0),
  ..._u32(ts),
  ..._i32(lat),
  ..._i32(lon),
  ..._u32(ts),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late OffbandDatabase db;
  late MeshCoreConnector c;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
    db = OffbandDatabase(NativeDatabase.memory());
    BlobStore.overrideForTest(BlobStore(db));
    c = MeshCoreConnector();
    c.setConnectedForTest();
    c.sendFrameOverrideForTest = (_) {};
  });

  tearDown(() async {
    await db.close();
    BlobStore.clearTestOverride();
  });

  Contact contact() => c.contacts.single;
  Contact discovered() => c.discoveredContacts.single;

  group('the radio record beats what the app stored', () {
    test('a 0,0 heard earlier does not hide the location the radio sends', () {
      c.handleFrameForTest(_rxAdvert(1000, lat: 0, lon: 0));

      c.handleFrameForTest(_radioRecord(2000, lat: _lat, lon: _lon));

      expect(contact().hasLocation, isTrue);
      expect(contact().latitude, closeTo(12.34567, 1e-6));
    });

    test('an older real location stored by the app does not win either', () {
      c.handleFrameForTest(_rxAdvert(1000, lat: 41000000, lon: -87000000));

      c.handleFrameForTest(_radioRecord(2000, lat: _lat, lon: _lon));

      expect(contact().latitude, closeTo(12.34567, 1e-6));
    });

    test('a live location survives the next contact sync', () {
      c.handleFrameForTest(_rxAdvert(1000, lat: 0, lon: 0));
      c.handleFrameForTest(_radioRecord(1000));
      c.handleFrameForTest(_rxAdvert(3000, lat: _lat, lon: _lon));

      c.handleFrameForTest(_radioRecord(3000, lat: _lat, lon: _lon));

      expect(contact().latitude, closeTo(12.34567, 1e-6));
    });

    test('a radio record with no location clears the old one', () {
      c.handleFrameForTest(_radioRecord(1000, lat: _lat, lon: _lon));

      c.handleFrameForTest(_radioRecord(2000));

      expect(contact().hasLocation, isFalse);
      expect(contact().latitude, isNull);
    });
  });

  group('the newest advert sets the location', () {
    setUp(() => c.handleFrameForTest(_radioRecord(1000, lat: _lat, lon: _lon)));

    test('an advert without a location withdraws it', () {
      c.handleFrameForTest(_rxAdvert(2000));

      expect(contact().latitude, isNull);
    });

    test('an advert with 0,0 withdraws it', () {
      c.handleFrameForTest(_rxAdvert(2000, lat: 0, lon: 0));

      expect(contact().latitude, isNull);
    });

    test('one advert from a clock set in the future does not freeze it', () {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      c.handleFrameForTest(_rxAdvert(now + 365 * 86400)); // clock a year ahead

      c.handleFrameForTest(_rxAdvert(now, lat: _lat, lon: _lon)); // clock fixed

      expect(contact().latitude, closeTo(12.34567, 1e-6));
    });

    test('an advert older than the one already applied changes nothing', () {
      c.handleFrameForTest(_rxAdvert(500));

      expect(contact().latitude, closeTo(12.34567, 1e-6));
      expect(contact().lastSeen.millisecondsSinceEpoch, 1000 * 1000);
    });
  });

  group('a node the radio did not save', () {
    test('0,0 is stored as unknown, never as a position', () {
      c.handleFrameForTest(_rxAdvert(1000, lat: 0, lon: 0, type: advTypeChat));

      expect(discovered().latitude, isNull);
      expect(discovered().longitude, isNull);
    });

    test('a later advert without a location withdraws the old one', () {
      c.handleFrameForTest(
        _rxAdvert(1000, lat: _lat, lon: _lon, type: advTypeChat),
      );

      c.handleFrameForTest(_rxAdvert(2000, type: advTypeChat));

      expect(discovered().latitude, isNull);
    });

    test('one advert from a clock set in the future does not freeze it', () {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      c.handleFrameForTest(_rxAdvert(now + 365 * 86400, type: advTypeChat));

      c.handleFrameForTest(
        _rxAdvert(now, lat: _lat, lon: _lon, type: advTypeChat),
      );

      expect(discovered().latitude, closeTo(12.34567, 1e-6));
    });

    test('an older advert does not roll the location back', () {
      c.handleFrameForTest(
        _rxAdvert(2000, lat: _lat, lon: _lon, type: advTypeChat),
      );

      c.handleFrameForTest(_rxAdvert(1000, type: advTypeChat));

      expect(discovered().latitude, closeTo(12.34567, 1e-6));
    });
  });
}
