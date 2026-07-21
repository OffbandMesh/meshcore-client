// Standalone web probe for #335.
//
// Loads ONLY the drift stack, so a pass or fail is unambiguous: it exercises
// sqlite3.wasm + drift_worker.js in a real browser without the rest of the app
// (BLE, permissions, radio) confusing the result.
//
// Renders the outcome into the DOM so the result is readable without a
// debugger attached.
import 'package:flutter/material.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';

void main() => runApp(const _ProbeApp());

class _ProbeApp extends StatelessWidget {
  const _ProbeApp();

  @override
  Widget build(BuildContext context) => const MaterialApp(
    home: Scaffold(body: Center(child: _Probe())),
  );
}

class _Probe extends StatefulWidget {
  const _Probe();

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  String _status = 'running…';

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    final lines = <String>[];
    OffbandDatabase? db;
    try {
      db = OffbandDatabase();

      final ok = await db.verifyReadWrite();
      final r1 = ok
          ? 'PROBE-OK open+write+read'
          : 'PROBE-FAIL readback mismatch';
      lines.add(r1);
      // ignore: avoid_print
      print(r1);

      // The point of the migration: exceed the 5 MiB localStorage ceiling.
      final big = 'x' * (6 * 1024 * 1024);
      await db
          .into(db.storedBlobs)
          .insertOnConflictUpdate(
            StoredBlobsCompanion.insert(key: 'big', value: big),
          );
      final row = await (db.select(
        db.storedBlobs,
      )..where((t) => t.key.equals('big'))).getSingle();
      final r2 = row.value.length == big.length
          ? 'PROBE-OK 6MiB round-trip (localStorage cap is 5MiB)'
          : 'PROBE-FAIL 6MiB truncated to ${row.value.length}';
      lines.add(r2);
      // ignore: avoid_print
      print(r2);

      await (db.delete(db.storedBlobs)..where((t) => t.key.equals('big'))).go();
    } catch (e) {
      lines.add('PROBE-FAIL $e');
      // ignore: avoid_print
      print('PROBE-FAIL $e');
    } finally {
      await db?.close();
    }
    if (mounted) setState(() => _status = lines.join('\n'));
  }

  @override
  Widget build(BuildContext context) => Text(
    _status,
    key: const Key('probe-result'),
    textAlign: TextAlign.center,
  );
}
