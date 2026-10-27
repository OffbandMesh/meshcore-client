import 'dart:isolate';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The one property Epic A (#919) delivers: the decode / merge / re-encode does
/// not run on the isolate that draws the UI.
///
/// Asserted structurally rather than by timing, because a wall-clock threshold
/// would be flaky on CI and would not say *why* it passed. If someone later
/// "simplifies" `mergeOffThread` back to an inline call, every other test in
/// this directory still passes and only this one fails.
void main() {
  late OffbandDatabase db;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
    db = OffbandDatabase(NativeDatabase.memory());
    BlobStore.overrideForTest(BlobStore(db));
  });

  tearDown(() async {
    await db.close();
    BlobStore.clearTestOverride();
  });

  test('the merge callback does not run on the main isolate', () async {
    final mainName = Isolate.current.debugName;
    expect(
      mainName,
      'main',
      reason: 'sanity check on the premise of this test',
    );

    await BlobStore.instance.write('k', 'ignored');
    final wrote = await BlobStore.instance.mergeOffThread(
      'k',
      'ignored',
      _reportIsolateName,
    );

    expect(wrote, isTrue);
    final ranOn = await BlobStore.instance.read('k');

    // `compute` names the isolate it spawns after the callback it was handed,
    // so the recorded name both proves this was not the main isolate and says
    // which worker it was. Observed: "Closure: ((String?, String)) => String
    // from Function '_reportIsolateName@...': static."
    expect(
      ranOn,
      isNot('main'),
      reason: 'the whole point of #919: this work must leave the UI isolate',
    );
    expect(
      ranOn,
      contains('_reportIsolateName'),
      reason:
          'a spawned compute worker is named after its callback; anything '
          'else means the merge ran somewhere unexpected',
    );
  });
}

/// Writes the name of the isolate it ran on, so the caller can check it.
String _reportIsolateName((String?, String) input) =>
    Isolate.current.debugName ?? 'unnamed';
