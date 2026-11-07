import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/models/channel.dart';
import 'package:meshcore_open/models/channel_message.dart';
import 'package:meshcore_open/screens/channel_chat_screen.dart';
import 'package:meshcore_open/services/app_settings_service.dart';
import 'package:meshcore_open/services/block_service.dart';
import 'package:meshcore_open/services/chat_text_scale_service.dart';
import 'package:meshcore_open/services/translation_service.dart';
import 'package:meshcore_open/services/ui_view_state_service.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #1052: iOS has no system Back, so a channel needs its own way out, and the
/// keyboard, which covers the bottom bar, needs a way to go away.
void main() {
  late OffbandDatabase db;
  final navKey = GlobalKey<NavigatorState>();

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
    debugDefaultTargetPlatformOverride = null;
  });

  Future<void> openChannel(
    WidgetTester t, {
    MeshCoreConnector? connector,
  }) async {
    final settings = AppSettingsService();
    await t.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<MeshCoreConnector>(
            create: (_) => connector ?? MeshCoreConnector(),
          ),
          ChangeNotifierProvider(create: (_) => settings),
          ChangeNotifierProvider(create: (_) => BlockService()),
          ChangeNotifierProvider(create: (_) => ChatTextScaleService()),
          ChangeNotifierProvider(create: (_) => TranslationService(settings)),
          ChangeNotifierProvider(create: (_) => UiViewStateService()),
        ],
        child: MaterialApp(
          navigatorKey: navKey,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: Text('CHANNEL LIST')),
        ),
      ),
    );
    navKey.currentState!.push(
      MaterialPageRoute(
        builder: (_) => ChannelChatScreen(
          channel: Channel(index: 1, name: 'Test', psk: Uint8List(16)),
        ),
      ),
    );
    await t.pumpAndSettle();
  }

  const messagesArea = Offset(400, 200);
  Finder composer() => find.byType(TextField);
  bool composerFocused(WidgetTester t) =>
      t.widget<TextField>(composer()).focusNode!.hasFocus;

  testWidgets('the back arrow leaves the channel', (t) async {
    await openChannel(t);
    expect(
      find.byIcon(Icons.menu),
      findsOneWidget,
      reason: 'panel still there',
    );

    await t.tap(find.byType(BackButton));
    await t.pumpAndSettle();

    expect(find.text('CHANNEL LIST'), findsOneWidget);
  });

  testWidgets('tapping the messages area dismisses the keyboard on iOS', (
    t,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await openChannel(t);
    await t.tap(composer());
    await t.pump();
    expect(composerFocused(t), isTrue);

    await t.tapAt(messagesArea);
    await t.pump();

    expect(composerFocused(t), isFalse);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('dragging the messages dismisses the keyboard on iOS', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await openChannel(t, connector: _LongChannel());
    await t.tap(composer());
    await t.pump();
    expect(composerFocused(t), isTrue);

    await t.dragFrom(messagesArea, const Offset(0, 100));
    await t.pump();

    expect(composerFocused(t), isFalse);
    await t.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a desktop trackpad scroll leaves the composer focused', (
    t,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await openChannel(t, connector: _LongChannel());

    expect(
      t.widget<ListView>(find.byType(ListView).first).keyboardDismissBehavior,
      ScrollViewKeyboardDismissBehavior.manual,
    );
    debugDefaultTargetPlatformOverride = null;
  });
}

class _LongChannel extends MeshCoreConnector {
  @override
  List<ChannelMessage> getChannelMessages(Channel channel) => [
    for (var i = 0; i < 60; i++)
      ChannelMessage(
        senderName: 'Other',
        text: 'hello $i',
        timestamp: DateTime(2026, 1, 1, 0, i),
        isOutgoing: false,
      ),
  ];
}
