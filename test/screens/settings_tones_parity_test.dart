// #970, #971, #986, #987: the approved parity screens
// (docs/initiatives/standalone/975-settings-restructure/
// tones-screen-parity-mockups.html). Pins the gates, that each list offers
// exactly what firmware accepts, that play never chooses, and that each
// control sends the documented request.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/offband_device_ui.dart';
import 'package:meshcore_open/connector/offband_screen_settings.dart';
import 'package:meshcore_open/connector/offband_tones.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/models/channel.dart';
import 'package:meshcore_open/screens/settings_screen.dart';
import 'package:meshcore_open/services/app_settings_service.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:meshcore_open/widgets/radio_tone.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:typed_data';

class _Radio extends MeshCoreConnector {
  _Radio({this.tunes = true, this.screen = true, this.playResult});
  final bool tunes;
  final bool screen;
  final TunePlayResult? playResult;
  final List<String> calls = [];

  ScreenSettingsState settings = const ScreenSettingsState(
    navText: BadgeTextSize.large,
    messageText: BadgeTextSize.medium,
    screenOffStored: 60,
    screenOffSeconds: 60,
    timeZone: 2,
    batteryFullStored: 0,
    batteryFullMv: 4200,
    batteryPinned: false,
  );

  @override
  bool get supportsNotifyScope => true;
  @override
  bool get supportsButtonMatrix => false;
  @override
  bool get supportsTunes => tunes;
  @override
  bool get supportsScreenSettings => screen;
  @override
  DeviceNotifyScope? get deviceNotifyScope => DeviceNotifyScope.all;

  @override
  EventToneState? eventTone(ToneEvent event) => switch (event) {
    ToneEvent.dm => const EventToneState(stored: 0xFF, effective: 1),
    ToneEvent.channel => const EventToneState(stored: 0xFF, effective: 2),
    ToneEvent.room => const EventToneState(stored: 8, effective: 8),
    _ => const EventToneState(stored: 0, effective: 0),
  };

  @override
  Map<int, TuneSlotInfo> get tuneSlots => {
    0: const TuneSlotInfo(length: 34, name: 'Mario'),
    for (var s = 1; s < tuneSlotCount; s++)
      s: const TuneSlotInfo(length: 0, name: ''),
  };

  @override
  ScreenSettingsState? get screenSettings => screen ? settings : null;

  @override
  ChannelTune? channelTuneFor(int channel) => const ChannelTune.inherit();

  @override
  Future<void> requestNotifyScope() async => calls.add('scope');
  @override
  Future<void> requestEventTones() async => calls.add('evtones');
  @override
  Future<void> requestTuneSlots() async => calls.add('slots');
  @override
  Future<void> requestScreenSettings() async => calls.add('screen');
  @override
  Future<void> requestChannelTune(int channel) async =>
      calls.add('chtune $channel');
  @override
  Future<void> setEventTone(ToneEvent event, int tuneId) async =>
      calls.add('evtone ${event.name} $tuneId');
  @override
  Future<void> setChannelTune(int channel, ChannelTune tune) async =>
      calls.add('chtune set $channel ${tune.stored}');
  @override
  Future<TunePlayResult?> playTune(int tuneId) async {
    calls.add('play $tuneId');
    return playResult ?? TunePlayResult.played;
  }

  @override
  Future<String?> readTuneSlot(
    int slot, {
    void Function(int bytesRead)? onProgress,
  }) async {
    calls.add('read $slot');
    return 'Mario:d=4,o=5,b=100:16e6,16e6,32p';
  }

  @override
  Future<void> setTextSize(BadgeTextTarget target, BadgeTextSize size) async =>
      calls.add('text ${target.name} ${size.name}');
  @override
  Future<void> setScreenOff(int seconds) async => calls.add('scroff $seconds');
  @override
  Future<void> setTimeZone(int index) async => calls.add('tz $index');
  @override
  Future<void> setBatteryFull({required bool pin}) async =>
      calls.add('batt ${pin ? 'pin' : 'auto'}');
}

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
    BlobStore.clearTestOverride();
    await db.close();
  });

  Future<void> pump(WidgetTester tester, _Radio radio, Widget home) async {
    radio.sendFrameOverrideForTest = (_) {};
    tester.view.physicalSize = const Size(400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<MeshCoreConnector>.value(value: radio),
          ChangeNotifierProvider<AppSettingsService>(
            create: (_) => AppSettingsService(),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: home,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapText(WidgetTester tester, String text) async {
    await tester.scrollUntilVisible(
      find.text(text),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    // scrollUntilVisible can stop with the row at the very edge, where a tap
    // lands on whatever is drawn over it.
    await tester.ensureVisible(find.text(text));
    await tester.pumpAndSettle();
    await tester.tap(find.text(text));
    await tester.pumpAndSettle();
  }

  Future<void> openBuzzer(WidgetTester tester, _Radio radio) async {
    await pump(tester, radio, const SettingsScreen());
    await tapText(tester, 'Message Settings');
    await tapText(tester, 'Buzzer and tones');
  }

  group('Buzzer and tones', () {
    testWidgets('scope, the six tones and all eight slots', (tester) async {
      final radio = _Radio();
      await openBuzzer(tester, radio);
      expect(radio.calls, containsAll(['scope', 'evtones', 'slots']));
      for (final e in ToneEvent.values) {
        await tester.scrollUntilVisible(
          find.text(e.label),
          100,
          scrollable: find.byType(Scrollable).last,
        );
        expect(find.text(e.label), findsOneWidget);
      }
      await tester.scrollUntilVisible(
        find.text('8 (empty)'),
        100,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.text('8 (empty)'), findsOneWidget);
    });

    testWidgets('a default and a choice never read alike', (tester) async {
      await openBuzzer(tester, _Radio());
      expect(find.text('Chime (radio default)'), findsOneWidget);
      expect(find.text('Mario'), findsOneWidget);
    });

    testWidgets('no 0x10: the scope alone, as before', (tester) async {
      final radio = _Radio(tunes: false);
      await openBuzzer(tester, radio);
      expect(find.text('Device notification scope'), findsOneWidget);
      expect(find.text('Tones'), findsNothing);
      expect(find.text('Custom tunes'), findsNothing);
      expect(radio.calls, isNot(contains('evtones')));
    });

    testWidgets('the picker lists what firmware accepts; play never chooses', (
      tester,
    ) async {
      final radio = _Radio();
      await openBuzzer(tester, radio);
      await tapText(tester, 'DM');

      final dialog = find.byType(AlertDialog);
      for (final name in [
        'Silent',
        'Chime',
        'Kerplop',
        'Tick',
        'Bloop',
        'Drop',
        'Knock',
        'Mario',
      ]) {
        expect(
          find.descendant(of: dialog, matching: find.text(name)),
          findsOneWidget,
        );
      }
      // No Default row for an event (owner decision 3), no empty slot.
      expect(
        find.descendant(of: dialog, matching: find.text('Default')),
        findsNothing,
      );
      expect(
        find.descendant(of: dialog, matching: find.textContaining('empty')),
        findsNothing,
      );

      final kerplop = find.ancestor(
        of: find.descendant(of: dialog, matching: find.text('Kerplop')),
        matching: find.byType(ListTile),
      );
      await tester.tap(
        find.descendant(
          of: kerplop,
          matching: find.byIcon(Icons.play_circle_outline),
        ),
      );
      await tester.pumpAndSettle();
      expect(radio.calls, contains('play 2'));
      expect(radio.calls.where((c) => c.startsWith('evtone ')), isEmpty);

      await tester.tap(
        find.descendant(of: dialog, matching: find.text('Bloop')),
      );
      await tester.pumpAndSettle();
      expect(radio.calls, contains('evtone dm 4'));
    });

    testWidgets('a silent preview says why', (tester) async {
      final radio = _Radio(playResult: TunePlayResult.soundOff);
      await openBuzzer(tester, radio);
      await tapText(tester, 'DM');
      final dialog = find.byType(AlertDialog);
      final chime = find.ancestor(
        of: find.descendant(of: dialog, matching: find.text('Chime')),
        matching: find.byType(ListTile),
      );
      await tester.tap(
        find.descendant(
          of: chime,
          matching: find.byIcon(Icons.play_circle_outline),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Sound is off on this radio'), findsOneWidget);
    });
  });

  group('slot editor', () {
    testWidgets('opens with the stored tune and checks typing', (tester) async {
      final radio = _Radio();
      await openBuzzer(tester, radio);
      await tapText(tester, '1 Mario');
      expect(radio.calls, contains('read 0'));
      expect(find.text('Mario:d=4,o=5,b=100:16e6,16e6,32p'), findsOneWidget);
      expect(find.text('Plays as "Mario"'), findsOneWidget);

      await tester.enterText(
        find.byType(TextField),
        'Doorbell:d=4,o=5,b=0:8e6',
      );
      await tester.pump();
      expect(find.text('b= must be 1 or more'), findsOneWidget);
      final save = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Save'),
      );
      expect(save.onPressed, isNull);
    });
  });

  group('Node Settings', () {
    testWidgets('Screen and Battery only with 0x40', (tester) async {
      await pump(tester, _Radio(screen: false), const SettingsScreen());
      await tapText(tester, 'Node Settings');
      expect(find.text('Screen'), findsNothing);
      expect(find.text('Battery'), findsNothing);
    });

    testWidgets('the Screen page sends each control\'s request', (
      tester,
    ) async {
      final radio = _Radio();
      await pump(tester, radio, const SettingsScreen());
      await tapText(tester, 'Node Settings');
      expect(find.text('100% at 4200 mV'), findsOneWidget);
      await tapText(tester, 'Screen');

      await tester.tap(find.text('Small').last);
      await tester.pumpAndSettle();
      expect(radio.calls, contains('text messages small'));

      await tester.tap(find.text('5 m'));
      await tester.pumpAndSettle();
      expect(radio.calls, contains('scroff 300'));

      await tapText(tester, 'Eastern');
      await tapText(tester, 'Central');
      expect(radio.calls, contains('tz 3'));
    });

    testWidgets('Battery: pin asks first; Back to auto only when set', (
      tester,
    ) async {
      final radio = _Radio();
      await pump(tester, radio, const SettingsScreen());
      await tapText(tester, 'Node Settings');
      await tapText(tester, 'Battery');
      expect(find.text('Default for this board'), findsOneWidget);
      expect(find.text('Back to auto'), findsNothing);

      await tester.tap(find.text('Set 100% here'));
      await tester.pumpAndSettle();
      expect(radio.calls, isNot(contains('batt pin')));
      await tester.tap(find.text('Set 100% here').last);
      await tester.pumpAndSettle();
      expect(radio.calls, contains('batt pin'));
    });
  });

  group('channel Radio tone', () {
    final channel = Channel(index: 3, name: '#okimesh', psk: Uint8List(16));

    Widget tile() => Scaffold(
      body: Builder(
        builder: (context) => ChannelRadioToneTile(
          channel: channel,
          onTap: () => showChannelRadioToneDialog(context, channel),
        ),
      ),
    );

    testWidgets('absent without 0x10', (tester) async {
      await pump(tester, _Radio(tunes: false), tile());
      expect(find.text('Radio tone'), findsNothing);
    });

    testWidgets('Default names what it plays, and is selectable', (
      tester,
    ) async {
      final radio = _Radio();
      await pump(tester, radio, tile());
      expect(radio.calls, contains('chtune 3'));
      expect(find.text('Default'), findsOneWidget);

      await tester.tap(find.text('Radio tone'));
      await tester.pumpAndSettle();
      expect(find.text('Kerplop, the radio\'s channel tone'), findsOneWidget);

      await tester.tap(find.text('Silent'));
      await tester.pumpAndSettle();
      expect(radio.calls, contains('chtune set 3 1'));
      // Let the refusal watcher's window close.
      await tester.pump(const Duration(seconds: 6));
    });
  });
}
