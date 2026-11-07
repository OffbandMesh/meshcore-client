// #1024 (epic #1021): every channel refusal message shows on its own failure,
// stays until dismissed, and is absent when the action is allowed.
//
// The messages are the whole point of the owner's ruling: block the unsafe
// write, keep the control live, and say why. A message that never shows, or
// that disappears in four seconds, is the silent failure that ruling rejects.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/helpers/channel_slot_ui.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/models/channel.dart';

class _FakeConn extends MeshCoreConnector {
  _FakeConn({this.list = const [], this.max = 40, this.busy = false});

  final List<Channel> list;
  final int max;
  final bool busy;

  @override
  List<Channel> get channels => list;
  @override
  int get maxChannels => max;
  @override
  bool get isChannelTableBusy => busy;
}

Channel _ch(int index, String name, int fill) => Channel(
  index: index,
  name: name,
  psk: Channel.parsePskHex(List.filled(32, fill.toRadixString(16)).join()),
);

final _l10n = lookupAppLocalizations(const Locale('en'));

/// Every refusal this file can show, so a success can assert none of them.
final _allMessages = [
  _l10n.channels_slotBusySyncing,
  _l10n.channels_slotsAllFull(3),
  _l10n.channels_publicAlreadyAdded,
  _l10n.channels_writeOccupied,
  _l10n.channels_writeRejected,
  _l10n.channels_writeNoReply,
  _l10n.channels_writeClearedNotAdded,
];

Future<BuildContext> _host(WidgetTester tester) async {
  late BuildContext context;
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Builder(
          builder: (c) {
            context = c;
            return const SizedBox.shrink();
          },
        ),
      ),
    ),
  );
  return context;
}

/// Shown, and still shown well past the 4 second toast default.
Future<void> _expectPersistent(WidgetTester tester, String message) async {
  await tester.pump();
  expect(find.text(message), findsOneWidget);
  await tester.pump(const Duration(seconds: 10));
  expect(find.text(message), findsOneWidget);
}

Future<void> _expectNoRefusal(WidgetTester tester) async {
  await tester.pump();
  for (final message in _allMessages) {
    expect(find.text(message), findsNothing, reason: message);
  }
}

void main() {
  group('allocateChannelSlotOrExplain', () {
    testWidgets('busy: refused, with the busy message', (tester) async {
      final context = await _host(tester);
      final slot = allocateChannelSlotOrExplain(context, _FakeConn(busy: true));

      expect(slot, isNull);
      await _expectPersistent(tester, _l10n.channels_slotBusySyncing);
    });

    testWidgets('full: refused, naming the slot count', (tester) async {
      final context = await _host(tester);
      final slot = allocateChannelSlotOrExplain(
        context,
        _FakeConn(
          list: [_ch(0, 'A', 1), _ch(1, 'B', 2), _ch(2, 'C', 3)],
          max: 3,
        ),
      );

      expect(slot, isNull);
      await _expectPersistent(tester, _l10n.channels_slotsAllFull(3));
    });

    testWidgets('a free slot: allowed, and no message', (tester) async {
      final context = await _host(tester);
      final slot = allocateChannelSlotOrExplain(
        context,
        _FakeConn(list: [_ch(0, 'A', 1)], max: 3),
      );

      expect(slot, 1);
      await _expectNoRefusal(tester);
    });
  });

  group('refusePublicAlreadyOnRadio', () {
    testWidgets('Public present, in any slot: refused', (tester) async {
      final context = await _host(tester);
      final publicPsk = Channel.parsePskHex(Channel.publicChannelPsk);
      final refused = refusePublicAlreadyOnRadio(
        context,
        _FakeConn(
          list: [Channel(index: 5, name: 'Public', psk: publicPsk)],
        ),
      );

      expect(refused, isTrue);
      await _expectPersistent(tester, _l10n.channels_publicAlreadyAdded);
    });

    testWidgets('no Public: allowed, and no message', (tester) async {
      final context = await _host(tester);
      final refused = refusePublicAlreadyOnRadio(
        context,
        _FakeConn(list: [_ch(0, 'A', 1)]),
      );

      expect(refused, isFalse);
      await _expectNoRefusal(tester);
    });
  });

  group('explainUnconfirmedChannelWrite', () {
    final cases = {
      ChannelWrite.occupied: _l10n.channels_writeOccupied,
      ChannelWrite.rejected: _l10n.channels_writeRejected,
      ChannelWrite.noReply: _l10n.channels_writeNoReply,
      ChannelWrite.clearedNotAdded: _l10n.channels_writeClearedNotAdded,
    };
    for (final entry in cases.entries) {
      testWidgets('${entry.key.name}: explained, persistently', (tester) async {
        final context = await _host(tester);

        expect(explainUnconfirmedChannelWrite(context, entry.key), isTrue);
        await _expectPersistent(tester, entry.value);
      });
    }

    testWidgets('ok: nothing to explain, and no message', (tester) async {
      final context = await _host(tester);

      expect(explainUnconfirmedChannelWrite(context, ChannelWrite.ok), isFalse);
      await _expectNoRefusal(tester);
    });
  });

  group('refuseWhileChannelTableBusy', () {
    testWidgets('busy: refused, with the busy message', (tester) async {
      final context = await _host(tester);

      expect(
        refuseWhileChannelTableBusy(context, _FakeConn(busy: true)),
        isTrue,
      );
      await _expectPersistent(tester, _l10n.channels_slotBusySyncing);
    });

    testWidgets('idle: allowed, and no message', (tester) async {
      final context = await _host(tester);

      expect(refuseWhileChannelTableBusy(context, _FakeConn()), isFalse);
      await _expectNoRefusal(tester);
    });
  });
}
