// Widget tests for the Device CLI console (#883, F2/E2.1).
//
// Pins the behaviors the owner-approved screen must hold: a correlated reply
// renders with a latency chip; a secret reply is MASKED (its cleartext never
// enters the widget tree); an error string gets the warning treatment; a reply
// at the device bound shows the truncation badge; a command with no answer
// renders a timeout row; and a blank command does nothing. Negative cases sit
// beside the positive ones so a regression in either direction fails CI.

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/cli_command_codec.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/screens/device_cli_screen.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late OffbandDatabase db;
  late MeshCoreConnector connector;
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
  });

  tearDown(() async {
    BlobStore.clearTestOverride();
    await db.close();
  });

  Future<void> pumpScreen(WidgetTester tester, {Duration? timeout}) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<MeshCoreConnector>.value(
        value: connector,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: DeviceCliScreen(commandTimeout: timeout),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Builds the `[29][prefix][text]` reply the device would send for the most
  /// recently captured request, mirroring its 3-char correlation reflection.
  Uint8List replyFor(Uint8List request, String text) {
    final prefix = ascii.decode(request.sublist(1, 4));
    return Uint8List.fromList([
      respCodeCliReply,
      ...ascii.encode('$prefix$text'),
    ]);
  }

  Future<void> send(WidgetTester tester, String command) async {
    await tester.enterText(find.byType(TextField), command);
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();
  }

  testWidgets('round trip: a correlated reply renders with a latency chip', (
    tester,
  ) async {
    await pumpScreen(tester);
    await send(tester, 'get radio');
    expect(sent, hasLength(1));

    connector.handleFrameForTest(replyFor(sent.single, '> 910.525,62.5,7,5'));
    await tester.pumpAndSettle();

    expect(find.text('> 910.525,62.5,7,5'), findsOneWidget);
    expect(find.textContaining(RegExp(r'\d+ ms')), findsOneWidget);
  });

  testWidgets('a secret reply is masked: cleartext never enters the tree', (
    tester,
  ) async {
    await pumpScreen(tester);
    await send(tester, 'get wifi.pwd');
    connector.handleFrameForTest(replyFor(sent.single, 'hunter2-secret'));
    await tester.pumpAndSettle();

    expect(find.text('hunter2-secret'), findsNothing);
    expect(find.textContaining('long-press to copy'), findsOneWidget);
  });

  testWidgets('any command containing pwd is treated as secret', (
    tester,
  ) async {
    await pumpScreen(tester);
    await send(tester, 'set wifi.pwd topsecret');
    connector.handleFrameForTest(replyFor(sent.single, 'topsecret'));
    await tester.pumpAndSettle();

    expect(find.text('topsecret'), findsNothing);
    expect(find.textContaining('long-press to copy'), findsOneWidget);
  });

  testWidgets('an error-string reply gets the warning glyph', (tester) async {
    await pumpScreen(tester);
    await send(tester, 'badcmd');
    connector.handleFrameForTest(replyFor(sent.single, 'Unknown command'));
    await tester.pumpAndSettle();

    expect(find.text('Unknown command'), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber), findsOneWidget);
  });

  testWidgets('a non-error reply gets no warning glyph', (tester) async {
    await pumpScreen(tester);
    await send(tester, 'get radio');
    connector.handleFrameForTest(replyFor(sent.single, '> ok'));
    await tester.pumpAndSettle();

    expect(find.text('> ok'), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber), findsNothing);
  });

  testWidgets('a reply at the device bound shows the truncation badge', (
    tester,
  ) async {
    await pumpScreen(tester);
    await send(tester, 'neighbors');
    // payloadLength (prefix + text) must reach maxCliReplyPayload (165).
    final text = 'x' * (maxCliReplyPayload - 3);
    connector.handleFrameForTest(replyFor(sent.single, text));
    await tester.pumpAndSettle();

    expect(find.textContaining('truncated by the device'), findsOneWidget);
  });

  testWidgets('a short reply shows no truncation badge', (tester) async {
    await pumpScreen(tester);
    await send(tester, 'ver');
    connector.handleFrameForTest(replyFor(sent.single, 'v1.18.0'));
    await tester.pumpAndSettle();

    expect(find.textContaining('truncated by the device'), findsNothing);
  });

  testWidgets('a command with no answer renders a timeout row', (tester) async {
    await pumpScreen(tester, timeout: const Duration(milliseconds: 120));
    await send(tester, 'get gps diag');
    // Let the window elapse without feeding a reply.
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();

    expect(find.textContaining('no reply'), findsOneWidget);
    expect(find.byIcon(Icons.timer_off_outlined), findsOneWidget);
  });

  testWidgets('a send failure renders the send-failed row', (tester) async {
    connector.sendFrameOverrideForTest = (_) => throw StateError('tx down');
    await pumpScreen(tester);
    await send(tester, 'get radio');
    await tester.pumpAndSettle();

    expect(find.textContaining('Send failed'), findsOneWidget);
  });

  testWidgets('a secret reply can be copied via long-press', (tester) async {
    final copied = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') copied.add(call);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await pumpScreen(tester);
    await send(tester, 'get wifi.pwd');
    connector.handleFrameForTest(replyFor(sent.single, 'topsecret'));
    await tester.pumpAndSettle();

    await tester.longPress(find.textContaining('long-press to copy'));
    await tester.pumpAndSettle();

    expect(copied, hasLength(1));
    expect(copied.single.arguments['text'], 'topsecret');
  });

  testWidgets('set name with a forbidden char is rejected client-side, not '
      'sent (#885)', (tester) async {
    await pumpScreen(tester);
    await tester.enterText(find.byType(TextField), 'set name My[Node]');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump(const Duration(milliseconds: 150)); // flush scroll timer

    expect(sent, isEmpty); // the frame never left the client
    expect(find.text('set name My[Node]'), findsOneWidget); // echoed
    expect(find.textContaining('Not sent'), findsOneWidget); // rejection row
    expect(find.textContaining('['), findsWidgets); // names the offender
  });

  testWidgets('a rejected set name is still recallable from history (#885 '
      'Gemini review)', (tester) async {
    // History derives from the command entries in the transcript, and the
    // rejection path adds the command entry, so up-arrow recalls it to fix.
    await pumpScreen(tester);
    await tester.enterText(find.byType(TextField), 'set name bad:name');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump(const Duration(milliseconds: 150));

    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller?.text, 'set name bad:name');
  });

  testWidgets('a valid set name is sent normally (#885)', (tester) async {
    await pumpScreen(tester);
    await send(tester, 'set name MyNode');
    expect(sent, hasLength(1));
    connector.handleFrameForTest(replyFor(sent.single, '> ok'));
    await tester.pumpAndSettle();
    expect(find.text('> ok'), findsOneWidget);
  });

  testWidgets('a blank command does nothing', (tester) async {
    await pumpScreen(tester);
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();

    expect(sent, isEmpty);
    // The empty-state hint is still the only thing on screen.
    expect(find.byIcon(Icons.terminal), findsOneWidget);
  });

  testWidgets('history recall walks back through sent commands', (
    tester,
  ) async {
    await pumpScreen(tester);
    await send(tester, 'get radio');
    connector.handleFrameForTest(replyFor(sent.single, '> ok'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller?.text, 'get radio');
  });
}
