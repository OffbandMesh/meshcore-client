import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_radio/fake_radio.dart';
import '../support/fake_radio/fake_radio_adapters.dart';
import '../support/fake_radio/fake_radio_codes.dart';
import '../support/fake_radio/fake_radio_seed.dart';

// #775 (B4 of #755): faults a test can script, on the fake clock.

Uint8List _cmd(List<int> b) => Uint8List.fromList(b);

Uint8List _dm(FakeContact to, String text) => Uint8List.fromList([
  fwCmdSendTxtMsg,
  fwTxtTypePlain,
  0,
  ...List<int>.filled(4, 0),
  ...to.publicKey.sublist(0, 6),
  ...utf8.encode(text),
  0,
]);

FakeRadioSeed _seed() => FakeRadioSeed(
  channels: [FakeChannel(index: 0, name: 'Public')],
  contacts: [
    FakeContact.keyed(0x11, 'Alpha'),
    FakeContact.keyed(0x22, 'Bravo'),
    FakeContact.keyed(0x33, 'Charlie'),
  ],
);

void main() {
  group('scripted faults (#775)', () {
    test('failNext: an ERR instead of the reply, then normal again', () {
      final r = FakeRadio()..failNext(fwCmdGetContacts, count: 2);
      expect(r.handle(_cmd([fwCmdGetContacts])).single, [
        fwRespErr,
        fwErrBadState,
      ]);
      expect(r.handle(_cmd([fwCmdGetContacts])).single[0], fwRespErr);
      expect(r.handle(_cmd([fwCmdGetContacts])).first[0], fwRespContactsStart);
    });

    test('delayNext: the reply arrives later, as a push', () {
      final r = FakeRadio()
        ..delayNext(fwCmdDeviceQuery, const Duration(seconds: 5));
      final pushes = <Uint8List>[];
      r.pushes.listen(pushes.add);
      expect(r.handle(_cmd([fwCmdDeviceQuery, 3])), isEmpty);
      r.clock.advance(const Duration(seconds: 4));
      expect(pushes, isEmpty);
      r.clock.advance(const Duration(seconds: 1));
      expect(pushes.single[0], fwRespDeviceInfo);
    });

    test('acksToDrop: that many ACKs never come back', () {
      final r = FakeRadio(seed: _seed())..acksToDrop = 1;
      final pushes = <Uint8List>[];
      r.pushes.listen(pushes.add);
      final alpha = r.contacts.first;
      r.handle(_dm(alpha, 'lost'));
      r.handle(_dm(alpha, 'kept'));
      r.clock.advance(const Duration(minutes: 1));
      expect(pushes.where((p) => p[0] == fwPushSendConfirmed), hasLength(1));
    });

    test(
      'cutContactsAfter: START and N contacts, no END, then a drop',
      () async {
        final r = FakeRadio(seed: _seed())..cutContactsAfter = 1;
        var dropped = false;
        r.drops.listen((_) => dropped = true);
        final out = r.handle(_cmd([fwCmdGetContacts]));
        expect(out.map((f) => f[0]), [fwRespContactsStart, fwRespContact]);
        expect(dropped, isFalse); // not before the partial stream is out
        await Future<void>.delayed(Duration.zero);
        expect(dropped, isTrue);
        // The next sync is whole again.
        expect(r.handle(_cmd([fwCmdGetContacts])).last[0], fwRespEndOfContacts);
      },
    );
  });

  group('a dropped link through the real connector', () {
    late OffbandDatabase db;
    late MeshCoreConnector connector;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      PrefsManager.reset();
      await PrefsManager.initialize();
      db = OffbandDatabase(NativeDatabase.memory());
      BlobStore.overrideForTest(BlobStore(db));
      connector = MeshCoreConnector();
    });

    tearDown(() async {
      await connector.disconnect();
      BlobStore.clearTestOverride();
      await db.close();
    });

    Future<void> untilDisconnected() async {
      final sw = Stopwatch()..start();
      while (connector.isConnected) {
        if (sw.elapsed > const Duration(seconds: 10)) fail('still connected');
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }

    test(
      'over TCP: a cut contact sync disconnects the client',
      () async {
        final r = FakeRadio(seed: _seed())..cutContactsAfter = 1;
        final server = await FakeRadioTcpServer.start(r);
        addTearDown(server.close);
        await connector.connectTcp(host: server.host, port: server.port);
        await untilDisconnected();
        expect(
          connector.contacts.map((c) => c.name),
          isNot(containsAll(['Alpha', 'Bravo', 'Charlie'])),
        );
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'in-process: a cut contact sync disconnects the client',
      () async {
        final r = FakeRadio(seed: _seed())..cutContactsAfter = 1;
        final link = await FakeRadioInProcess.connect(connector, r);
        addTearDown(link.close);
        await untilDisconnected();
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });
}
