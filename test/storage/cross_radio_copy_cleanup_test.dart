// #1163: channel messages a Bluetooth radio switch copied into another radio's
// history. A copy keeps the original's receive time exactly; the original is on
// the radio that was connected when the message arrived.

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/storage/cross_radio_copy_cleanup.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';

const _a = 'aaaaaaaaaa';
const _b = 'bbbbbbbbbb';
String _key(String radio, String psk) => 'channel_messages_${radio}psk_$psk';

const _min = 60 * 1000;
const _t0 = 1_800_000_000_000;

ScannedRow _row(String storeKey, String mergeKey, int rxTime) =>
    (storeKey: storeKey, mergeKey: mergeKey, rxTime: rxTime);

// [radio] was connected around [at]: a few receptions only it holds.
List<ScannedRow> _session(String radio, int at, String tag) => [
  for (var i = 0; i < 3; i++)
    _row(_key(radio, 'own'), '$tag-own-$i', at + i * _min),
];

void main() {
  group('findCrossRadioCopies', () {
    test('the field pattern: radio A received it, radio B holds a copy', () {
      final rows = [
        ..._session(_a, _t0, 'a'),
        ..._session(_b, _t0 + 6 * 60 * _min, 'b'), // B connected 6 hours later
        _row(_key(_a, 'claude'), 'alert', _t0 + _min),
        _row(_key(_b, 'offband'), 'alert', _t0 + _min), // same slot on B
      ];

      final decision = findCrossRadioCopies(rows);

      expect(decision.copies.map((r) => r.storeKey), [_key(_b, 'offband')]);
      expect(decision.undecided, 0);
    });

    test('a message both radios heard, at different times, is no copy', () {
      final rows = [
        ..._session(_a, _t0, 'a'),
        ..._session(_b, _t0 + 6 * 60 * _min, 'b'),
        _row(_key(_a, 'public'), 'heard-twice', _t0 + _min),
        _row(_key(_b, 'public'), 'heard-twice', _t0 + 6 * 60 * _min + _min),
      ];

      final decision = findCrossRadioCopies(rows);

      expect(decision.copies, isEmpty);
      expect(decision.undecided, 0);
    });

    test(
      'a copy with no connection evidence on either radio is left alone',
      () {
        final rows = [
          ..._session(_a, _t0, 'a'),
          ..._session(_b, _t0 + 6 * 60 * _min, 'b'),
          // Three days away from both sessions: nothing says who heard it.
          _row(_key(_a, 'echo'), 'orphan', _t0 + 3 * 24 * 60 * _min),
          _row(_key(_b, 'test'), 'orphan', _t0 + 3 * 24 * 60 * _min),
        ];

        final decision = findCrossRadioCopies(rows);

        expect(decision.copies, isEmpty);
        expect(decision.undecided, 1);
      },
    );

    test('two radios both connected at that time: left alone', () {
      final rows = [
        ..._session(_a, _t0, 'a'),
        ..._session(_b, _t0, 'b'),
        _row(_key(_a, 'echo'), 'either', _t0 + _min),
        _row(_key(_b, 'test'), 'either', _t0 + _min),
      ];

      final decision = findCrossRadioCopies(rows);

      expect(decision.copies, isEmpty);
      expect(decision.undecided, 1);
    });
  });

  group('CrossRadioCopyCleanup.run', () {
    late OffbandDatabase db;
    late BlobStore blobs;

    setUp(() {
      db = OffbandDatabase(NativeDatabase.memory());
      blobs = BlobStore(db);
    });

    tearDown(() => db.close());

    Future<void> store(String key, String mergeKey, int rxTime) =>
        blobs.upsertMessageRows(key, [
          MessageRowInput(
            mergeKey: mergeKey,
            timestampMs: rxTime,
            payload: jsonEncode({'text': mergeKey, 'rxTime': rxTime}),
          ),
        ]);

    Future<void> seedFieldPattern() async {
      for (final r in [
        ..._session(_a, _t0, 'a'),
        ..._session(_b, _t0 + 6 * 60 * _min, 'b'),
        _row(_key(_a, 'claude'), 'alert', _t0 + _min),
        _row(_key(_b, 'offband'), 'alert', _t0 + _min),
      ]) {
        await store(r.storeKey, r.mergeKey, r.rxTime!);
      }
    }

    test(
      'holds the copy aside, keeps the original, and can be undone',
      () async {
        await seedFieldPattern();

        await CrossRadioCopyCleanup.run(blobs);

        expect(await blobs.messageMergeKeys(_key(_b, 'offband')), isEmpty);
        expect(await blobs.messageMergeKeys(_key(_a, 'claude')), {'alert'});
        final held =
            '${CrossRadioCopyCleanup.heldPrefix}${_key(_b, 'offband')}';
        expect(
          await blobs.messageMergeKeys(held),
          {'alert'},
          reason:
              'held, not deleted: the copy is kept where it can be put back',
        );
        final marker = jsonDecode(
          (await blobs.read(CrossRadioCopyCleanup.doneMarkerKey))!,
        );
        expect(marker['held'], 1);
        expect(marker['undecided'], 0);
      },
    );

    test(
      'runs once: a later launch does not touch the history again',
      () async {
        await seedFieldPattern();
        await CrossRadioCopyCleanup.run(blobs);

        // A new copy appearing afterwards is not this cleanup's business.
        await store(_key(_b, 'public'), 'later', _t0 + 2 * _min);
        await store(_key(_a, 'public'), 'later', _t0 + 2 * _min);
        await CrossRadioCopyCleanup.run(blobs);

        expect(await blobs.messageMergeKeys(_key(_b, 'public')), {'later'});
      },
    );
  });
}
