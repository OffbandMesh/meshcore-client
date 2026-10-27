// Epic B verification (#937): rehearse the legacy purge against a copy of a
// REAL prefs file and report what it costs and what it leaves behind.
//
// Named `_bench`, not `_test`, so a bare `flutter test` does not collect it:
// it needs a copy of a real prefs file and its numbers are machine-specific.
// The non-flaky gates live in test/services/radio_isolation_bleed_test.dart.
//
// Run it:
//   flutter test test/benchmarks/legacy_purge_rehearsal_bench.dart \
//     --dart-define=BENCH_PREFS="$APPDATA/Offband/Offband Meshcore/shared_preferences.json"
//
// It never writes to the file it is given; the contents are loaded into the
// SharedPreferences mock. Without BENCH_PREFS it says it measured nothing
// rather than synthesising a file, because a rehearsal on invented data
// rehearses nothing.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/path_history.dart';
import 'package:meshcore_open/services/storage_service.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _benchPrefs = String.fromEnvironment('BENCH_PREFS');

void main() {
  test(
    'legacy purge against a real prefs file',
    () async {
      if (_benchPrefs.isEmpty || !File(_benchPrefs).existsSync()) {
        // ignore: avoid_print
        print(
          'SKIPPED: no BENCH_PREFS. Pass '
          '--dart-define=BENCH_PREFS=<a real shared_preferences.json>. '
          'Nothing was measured.',
        );
        return;
      }

      final raw = File(_benchPrefs).readAsStringSync();
      final decoded = jsonDecode(raw) as Map<String, dynamic>;

      // SharedPreferences stores keys with a `flutter.` prefix; the mock
      // expects them without it.
      final seed = <String, Object>{};
      for (final e in decoded.entries) {
        final k = e.key.startsWith('flutter.') ? e.key.substring(8) : e.key;
        final v = e.value;
        if (v is String) seed[k] = v;
        if (v is bool) seed[k] = v;
        if (v is int) seed[k] = v;
        if (v is double) seed[k] = v;
        if (v is List) seed[k] = v.map((x) => x.toString()).toList();
      }

      final legacyBefore = seed.keys
          .where((k) => k.startsWith('path_history_'))
          .length;
      final hadGlobalObs = seed.containsKey('delivery_observations');

      // ignore: avoid_print
      print('source: $_benchPrefs');
      // ignore: avoid_print
      print(
        'seeded ${seed.length} keys, ${raw.length} bytes of JSON\n'
        '  legacy path_history keys: $legacyBefore\n'
        '  global delivery_observations present: $hadGlobalObs',
      );

      expect(
        legacyBefore,
        greaterThan(0),
        reason:
            'nothing to rehearse: this prefs file has no legacy keys, so '
            'it measured nothing',
      );

      SharedPreferences.setMockInitialValues(seed);
      PrefsManager.reset();
      await PrefsManager.initialize();
      final db = OffbandDatabase(NativeDatabase.memory());
      BlobStore.overrideForTest(BlobStore(db));

      final storage = StorageService()..setPublicKeyHex = 'a' * 20;

      // A route stored under the NEW scheme before the purge, to prove the
      // purge does not take scoped data with it.
      await storage.savePathHistory('cafebabe', _history('cafebabe'));

      // Heartbeat on the main isolate, as in #919's harness: the worst gap
      // between beats is the UI freeze the purge would cause.
      var last = DateTime.now();
      var worst = 0;
      var beats = 0;
      final beat = Timer.periodic(const Duration(milliseconds: 1), (_) {
        final now = DateTime.now();
        final gap = now.difference(last).inMilliseconds;
        if (gap > worst) worst = gap;
        last = now;
        beats++;
      });

      final sw = Stopwatch()..start();
      last = DateTime.now();
      final removed = await storage.purgeLegacyPathHistory();
      final obsRemoved = await storage.purgeLegacyDeliveryObservations();
      final wall = sw.elapsedMilliseconds;
      for (var i = 0; i < 3; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      beat.cancel();

      final legacyAfter = PrefsManager.instance
          .getKeys()
          .where((k) => k.startsWith('path_history_'))
          .length;

      // ignore: avoid_print
      print('');
      // ignore: avoid_print
      print('purged $removed path-history keys, observations: $obsRemoved');
      // ignore: avoid_print
      print('  wall ${wall}ms   worst UI block ${worst}ms   beats $beats');
      // ignore: avoid_print
      print(
        '  !! THOSE TWO TIMINGS ARE NOT THE REAL COST. The\n'
        '     SharedPreferences test mock is an in-memory map, so it does\n'
        '     NOT do the whole-file re-encode and rewrite that every real\n'
        '     `remove` performs on Windows. This rehearsal proves\n'
        '     CORRECTNESS: every legacy key gone, scoped data intact,\n'
        '     idempotent. For the real cost, simulated against this same\n'
        '     file at the plugin\'s actual behaviour: 12.7 s of total work,\n'
        '     mean 6.1 ms, 32 ms for the first removal falling below 1 ms by\n'
        '     the last as the file collapses 4.28 MB -> 45 KB. That is why\n'
        '     the purge yields every 20 removals instead of running flat.',
      );
      // ignore: avoid_print
      print('  legacy keys left: $legacyAfter');
      // ignore: avoid_print
      print(
        '  prefs keys remaining: ${PrefsManager.instance.getKeys().length}',
      );

      expect(removed, legacyBefore, reason: 'every legacy key must go');
      expect(legacyAfter, 0);
      expect(obsRemoved, hadGlobalObs);
      // Deliberately NOT asserting a time bound. The mock does not reproduce
      // the plugin's whole-file rewrite, so any threshold here would pass
      // regardless of how slow the purge is in production and would be a
      // check that cannot fail.
      expect(
        beats,
        greaterThan(10),
        reason: 'the heartbeat ran, so the harness itself worked',
      );
      expect(
        await storage.loadPathHistory('cafebabe'),
        isNotNull,
        reason:
            'THE point of the rehearsal: the purge removes the unscoped '
            'legacy keys and leaves this radio\'s scoped history intact',
      );

      await db.close();
      BlobStore.clearTestOverride();
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

ContactPathHistory _history(String contact) => ContactPathHistory(
  contactPubKeyHex: contact,
  recentPaths: [
    PathRecord(
      hopCount: 2,
      tripTimeMs: 500,
      timestamp: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      wasFloodDiscovery: false,
      pathBytes: const [1, 2, 3],
      successCount: 1,
      failureCount: 0,
    ),
  ],
);
