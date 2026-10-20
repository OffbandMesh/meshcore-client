import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/message.dart';
import 'package:meshcore_open/screens/channel_chat_screen.dart';
import 'package:meshcore_open/screens/chat_screen.dart';
import 'package:meshcore_open/widgets/message_status_icon.dart';

import '../support/fake_radio/fake_radio.dart';
import '../support/fake_radio/fake_radio_adapters.dart';
import '../support/fake_radio/fake_radio_app.dart';
import '../support/fake_radio/fake_radio_seed.dart';

// #779 (C2 of #755): the real chat screens, attached in-process to the fake
// radio. A composer send reaches the radio and its outcome shows.

void main() {
  late FakeRadioAppServices services;
  late FakeRadio radio;
  late FakeRadioInProcess link;

  Future<void> realWait(bool Function() done, String what) async {
    final sw = Stopwatch()..start();
    while (!done()) {
      if (sw.elapsed > const Duration(seconds: 15)) fail('timed out: $what');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  /// Waits for [done] while moving both clocks: the widget test's fake clock
  /// (the retry service and screens schedule on it) and real time (the
  /// in-memory database answers on it).
  Future<void> settle(
    WidgetTester tester,
    bool Function() done,
    String what,
  ) async {
    for (var i = 0; i < 300 && !done(); i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
    }
    if (!done()) fail('timed out: $what');
    await tester.pump();
  }

  Future<void> connect(WidgetTester tester) async {
    await tester.runAsync(() async {
      services = await FakeRadioAppServices.create();
      radio = FakeRadio(
        seed: FakeRadioSeed(
          // A contact with a learned route: the screen marks a message as
          // acked only when it was delivered over a known path.
          contacts: [
            FakeContact(
              publicKey: Uint8List.fromList(List<int>.filled(32, 0x11)),
              name: 'Alpha',
              outPathLength: 1,
              outPath: Uint8List.fromList([0x9A]),
            ),
          ],
          channels: [FakeChannel(index: 0, name: 'Public')],
        ),
      )..ackDelay = const Duration(seconds: 1);
      link = await FakeRadioInProcess.connect(services.connector, radio);
      await realWait(
        () =>
            services.connector.contacts.isNotEmpty &&
            services.connector.channels.isNotEmpty,
        'contacts and channels',
      );
    });
  }

  Future<void> teardown(WidgetTester tester) async {
    await tester.runAsync(() async {
      await link.close();
      await services.dispose();
    });
    // Let screen timers (typing indicators, retry timeouts) run out.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 5));
  }

  Future<void> typeAndSend(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField).last, text);
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send).last);
    await tester.pump();
  }

  testWidgets('chat screen: a sent DM shows delivered when the ACK lands', (
    tester,
  ) async {
    await connect(tester);
    final alpha = services.connector.contacts.single;
    await tester.pumpWidget(services.app(ChatScreen(contact: alpha)));
    await tester.pump();

    await typeAndSend(tester, 'hello from the screen');
    await settle(
      tester,
      () => radio.sentDirect.any((s) => s.text == 'hello from the screen'),
      'the DM at the radio',
    );
    expect(find.text('hello from the screen'), findsOneWidget);

    bool acked() => tester
        .widgetList<MessageStatusIcon>(find.byType(MessageStatusIcon))
        .any((i) => i.isAcked);
    expect(acked(), isFalse);

    // The recipient's ACK arrives.
    radio.clock.advance(const Duration(seconds: 1));
    await settle(tester, acked, 'the delivered mark');
    expect(
      services.connector.getMessages(alpha).single.status,
      MessageStatus.delivered,
    );

    await teardown(tester);
  });

  testWidgets('channel screen: a sent message reaches the radio and shows', (
    tester,
  ) async {
    await connect(tester);
    final channel = services.connector.channels.firstWhere(
      (c) => c.name == 'Public',
    );
    await tester.pumpWidget(services.app(ChannelChatScreen(channel: channel)));
    await tester.pump();

    await typeAndSend(tester, 'hi channel');
    await settle(
      tester,
      () => radio.sentChannel.any((s) => s.text == 'hi channel'),
      'the channel message at the radio',
    );
    expect(radio.sentChannel.single.index, 0);
    expect(find.textContaining('hi channel'), findsWidgets);

    await teardown(tester);
  });
}
