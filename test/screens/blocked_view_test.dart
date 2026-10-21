import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/screens/settings/blocked_view.dart';
import 'package:meshcore_open/services/block_service.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #938 (#507): the Blocked pane is per radio, and says so.
///
/// The gap this closes: with no radio connected the pane rendered "No blocked
/// users", which is indistinguishable from a connected radio with an empty
/// list. Since #471 made blocks per radio, that wording invited the reader to
/// conclude their blocks had been lost.
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

  Widget harness(BlockService block) => MultiProvider(
    providers: [
      ChangeNotifierProvider<BlockService>.value(value: block),
      ChangeNotifierProvider<MeshCoreConnector>(
        create: (_) => MeshCoreConnector(),
      ),
    ],
    child: const MaterialApp(
      localizationsDelegates: [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      home: Scaffold(body: BlockedView()),
    ),
  );

  group('the two empty states read differently', () {
    testWidgets('no radio connected says so, and explains why', (t) async {
      final block = BlockService();
      await block.loadForDevice(null);

      await t.pumpWidget(harness(block));
      await t.pumpAndSettle();

      expect(find.text('No radio connected'), findsOneWidget);
      expect(
        find.textContaining('Blocks belong to the radio that holds them'),
        findsOneWidget,
        reason: 'the reason matters: without it the pane looks like data loss',
      );
      expect(
        find.text('No blocked users'),
        findsNothing,
        reason: 'this was the bug: both states said the same thing',
      );
    });

    testWidgets('a connected radio with nothing blocked says THAT', (t) async {
      final block = BlockService();
      await block.loadForDevice('aa' * 16);

      await t.pumpWidget(harness(block));
      await t.pumpAndSettle();

      expect(find.text('No blocked users'), findsOneWidget);
      expect(find.text('No radio connected'), findsNothing);
    });
  });

  group('per-radio isolation through the pane', () {
    testWidgets('a block made on radio A is absent on radio B', (t) async {
      final block = BlockService();
      await block.loadForDevice('aa' * 16);
      await block.block('deadbeef');

      await t.pumpWidget(harness(block));
      await t.pumpAndSettle();
      expect(find.textContaining('deadbeef'), findsOneWidget);

      // Switch radios, as the connector does on SELF_INFO.
      await block.loadForDevice('bb' * 16);
      await t.pumpAndSettle();

      expect(
        find.textContaining('deadbeef'),
        findsNothing,
        reason: 'radio A\'s block must not appear while radio B is connected',
      );
      expect(find.text('No blocked users'), findsOneWidget);
    });

    testWidgets('switching back restores radio A\'s list', (t) async {
      final block = BlockService();
      await block.loadForDevice('aa' * 16);
      await block.block('deadbeef');
      await block.loadForDevice('bb' * 16);
      await block.loadForDevice('aa' * 16);

      await t.pumpWidget(harness(block));
      await t.pumpAndSettle();

      expect(
        find.textContaining('deadbeef'),
        findsOneWidget,
        reason: 'isolation is not deletion: A keeps its own list',
      );
    });
  });

  group('unblock sticks', () {
    testWidgets('an unblock survives a radio switch and back', (t) async {
      final block = BlockService();
      await block.loadForDevice('aa' * 16);
      await block.block('deadbeef');
      await block.unblock('deadbeef');

      await block.loadForDevice('bb' * 16);
      await block.loadForDevice('aa' * 16);

      await t.pumpWidget(harness(block));
      await t.pumpAndSettle();

      expect(
        find.textContaining('deadbeef'),
        findsNothing,
        reason:
            'the clear-sticks case from #507: the re-clear that kept '
            'recurring was #471, and it must not come back',
      );
    });
  });
}
