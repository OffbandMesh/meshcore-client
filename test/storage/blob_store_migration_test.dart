import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Migration safety for #335.
///
/// The bar here is set by #333: a storage path chose a key silently and 566
/// real messages read as empty. A migration that gets this wrong loses data
/// permanently rather than cosmetically, so the failure paths are tested, not
/// just the happy one.
void main() {
  late OffbandDatabase db;
  late BlobStore store;

  setUp(() async {
    db = OffbandDatabase(NativeDatabase.memory());
    store = BlobStore(db);
    PrefsManager.reset();
  });

  tearDown(() => db.close());

  Future<void> seedPrefs(Map<String, Object> values) async {
    SharedPreferences.setMockInitialValues(values);
    await PrefsManager.initialize();
  }

  test('moves bulk keys and removes them from prefs', () async {
    await seedPrefs({
      'channel_messages_devpsk_abc': '[{"m":1}]',
      'messages_devcontact': '[{"m":2}]',
      'contacts_dev': '[{"c":1}]',
      'discovered_contacts': '[{"d":1}]',
    });

    final report = await store.migrateFromPrefs();

    expect(report.migrated, 4);
    expect(report.failed, 0);
    expect(await store.read('channel_messages_devpsk_abc'), '[{"m":1}]');
    expect(await store.read('discovered_contacts'), '[{"d":1}]');

    final prefs = PrefsManager.instance;
    expect(prefs.getString('channel_messages_devpsk_abc'), isNull);
    expect(prefs.getString('discovered_contacts'), isNull);
  });

  test('leaves settings alone', () async {
    await seedPrefs({
      'ui_channels_sort_option': 'manual',
      'app_settings': '{"theme":"dark"}',
      'contacts_dev': '[{"c":1}]',
    });

    final report = await store.migrateFromPrefs();

    expect(report.migrated, 1, reason: 'only the bulk key should move');
    final prefs = PrefsManager.instance;
    expect(prefs.getString('ui_channels_sort_option'), 'manual');
    expect(prefs.getString('app_settings'), '{"theme":"dark"}');
  });

  test('is idempotent: a second run moves nothing and loses nothing', () async {
    await seedPrefs({'contacts_dev': '[{"c":1}]'});

    final first = await store.migrateFromPrefs();
    expect(first.migrated, 1);

    final second = await store.migrateFromPrefs();
    expect(second.migrated, 0);
    expect(second.failed, 0);
    expect(await store.read('contacts_dev'), '[{"c":1}]');
  });

  test('a re-added prefs key does not clobber migrated data', () async {
    // Simulates an older build writing the key again after migration. The
    // migrated copy must win; the stale prefs copy is discarded, not promoted.
    await seedPrefs({'contacts_dev': '[{"c":"new"}]'});
    await store.write('contacts_dev', '[{"c":"migrated"}]');

    final report = await store.migrateFromPrefs();

    expect(report.alreadyPresent, 1);
    expect(await store.read('contacts_dev'), '[{"c":"migrated"}]');
    expect(PrefsManager.instance.getString('contacts_dev'), isNull);
  });

  test('preserves a payload larger than the 5 MiB localStorage cap', () async {
    // 4 chars per element, so >1.4M elements clears 5 MiB.
    final big = '[${'"x",' * 1400000}"end"]';
    expect(big.length, greaterThan(5 * 1024 * 1024));
    await seedPrefs({'channel_messages_devpsk_big': big});

    final report = await store.migrateFromPrefs();

    expect(report.failed, 0);
    expect(
      (await store.read('channel_messages_devpsk_big'))!.length,
      big.length,
    );
  });

  test('non-string values are skipped, not failed', () async {
    // getString THROWS on a non-string, so this must be type-checked, not
    // caught as a failure. Verified against the real store: 'contacts' only
    // ever matches bulk blobs there, but the store must not mis-report if a
    // non-string ever lands under a bulk prefix.
    await seedPrefs({'contacts_probe': 42});

    final report = await store.migrateFromPrefs();

    expect(report.failed, 0);
    expect(report.skipped, 1);
  });
}
