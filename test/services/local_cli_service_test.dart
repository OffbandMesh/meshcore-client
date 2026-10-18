import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/cli_command_codec.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/services/command_correlation.dart';
import 'package:meshcore_open/services/local_cli_service.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('PrefixAllocator / splitCorrelated', () {
    test('allocates unique XX| tokens and skips in-flight ones', () {
      final a = PrefixAllocator();
      expect(a.next({}), '00|');
      expect(a.next({}), '01|');
      expect(a.next({'02|'}), '03|');
    });

    test('wraps after 256 tokens', () {
      final a = PrefixAllocator();
      for (var i = 0; i < 256; i++) {
        a.next({});
      }
      expect(a.next({}), '00|');
    });

    test('split honors the positional rule', () {
      final c = splitCorrelated('0A|  > ok');
      expect(c.prefix, '0A|');
      expect(c.payload, '> ok');
      final plain = splitCorrelated('Unknown command');
      expect(plain.prefix, isNull);
      expect(plain.payload, 'Unknown command');
    });
  });

  group('LocalCliService', () {
    late OffbandDatabase db;
    late MeshCoreConnector connector;
    late LocalCliService service;
    late List<Uint8List> sent;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      PrefsManager.reset();
      await PrefsManager.initialize();
      db = OffbandDatabase(NativeDatabase.memory());
      BlobStore.overrideForTest(BlobStore(db));
      connector = MeshCoreConnector();
      sent = [];
      connector.sendFrameOverrideForTest = sent.add;
      connector.setConnectedForTest();
      service = LocalCliService(connector);
    });

    tearDown(() async {
      service.dispose();
      BlobStore.clearTestOverride();
      await db.close();
    });

    Uint8List replyFor(Uint8List request, String text) {
      final prefix = ascii.decode(request.sublist(1, 4));
      return Uint8List.fromList([
        respCodeCliReply,
        ...ascii.encode('$prefix$text'),
      ]);
    }

    test('round trip: command out, correlated reply completes it', () async {
      final future = service.run('get radio');
      expect(sent, hasLength(1));
      expect(sent.single[0], cmdRunCliCommand);
      connector.handleFrameForTest(replyFor(sent.single, '> 910.525,62.5,7,5'));
      final reply = await future;
      expect(reply.text, '> 910.525,62.5,7,5');
      expect(reply.prefix, isNotNull);
    });

    test('a reply with a foreign prefix never completes a waiting command'
        ' - the command times out instead', () async {
      final future = service.run(
        'ver',
        timeout: const Duration(milliseconds: 80),
      );
      connector.handleFrameForTest(
        Uint8List.fromList([respCodeCliReply, ...ascii.encode('ZZ|nope')]),
      );
      await expectLater(future, throwsA(isA<LocalCliTimeout>()));
    });

    test('timeout surfaces as LocalCliTimeout', () async {
      final future = service.run(
        'ver',
        timeout: const Duration(milliseconds: 50),
      );
      await expectLater(future, throwsA(isA<LocalCliTimeout>()));
    });

    test('two in-flight commands complete independently', () async {
      final f1 = service.run('get af');
      final f2 = service.run('get cad');
      expect(sent, hasLength(2));
      // Answer the SECOND first; each reply must find its own command.
      connector.handleFrameForTest(replyFor(sent[1], '> off'));
      connector.handleFrameForTest(replyFor(sent[0], '> 1.0'));
      expect((await f2).text, '> off');
      expect((await f1).text, '> 1.0');
    });
  });
}
