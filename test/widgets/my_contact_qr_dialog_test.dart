// Widget tests for sharing this device's own identity as a QR (#629).
//
// The QR is only the meshcore://contact/add link rendered visually. qr_flutter
// keeps its payload private (`final String? _data`), so these assert on the
// link the dialog renders beside the code, which is the same string, and on
// that link parsing back into the right key, name and type.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/widgets/my_contact_qr_dialog.dart';

const _key = 'aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899';

class _FakeConn extends MeshCoreConnector {
  _FakeConn({required this.keyHex, this.nodeName});

  final String keyHex;
  final String? nodeName;

  @override
  String get selfPublicKeyHex => keyHex;

  @override
  String? get selfName => nodeName;
}

Future<void> _open(WidgetTester tester, MeshCoreConnector conn) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<MeshCoreConnector>.value(
      value: conn,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showMyContactQrDialog(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders a QR plus the link it encodes', (tester) async {
    await _open(tester, _FakeConn(keyHex: _key, nodeName: 'Strycher-RK4'));

    final expected = Contact.buildShareUri(
      publicKeyHex: _key,
      name: 'Strycher-RK4',
      type: advTypeChat,
    );

    expect(find.byType(QrImageView), findsOneWidget);
    // The link is shown so it can be copied or pasted into a chat, which is
    // the path that works when the other person is not in the room.
    expect(find.text(expected), findsOneWidget);
  });

  testWidgets('the rendered link parses back to this device', (tester) async {
    await _open(tester, _FakeConn(keyHex: _key, nodeName: 'Strycher-RK4'));

    final expected = Contact.buildShareUri(
      publicKeyHex: _key,
      name: 'Strycher-RK4',
      type: advTypeChat,
    );
    final parsed = Contact.fromShareUri(expected);

    expect(parsed, isNotNull);
    expect(parsed!.publicKeyHex, _key);
    expect(parsed.name, 'Strycher-RK4');
    // This device is a companion, not a repeater.
    expect(parsed.type, advTypeChat);
  });

  testWidgets('a node with no name still produces an addable link', (
    tester,
  ) async {
    await _open(tester, _FakeConn(keyHex: _key));

    final expected = Contact.buildShareUri(
      publicKeyHex: _key,
      name: '',
      type: advTypeChat,
    );
    expect(find.text(expected), findsOneWidget);
    // The key is the identity, so a nameless link is still usable.
    expect(Contact.fromShareUri(expected)?.publicKeyHex, _key);
  });

  testWidgets('with no connection nothing is rendered, since we lack our key', (
    tester,
  ) async {
    // An empty key would encode a QR that cannot be added, which is worse
    // than refusing to show one.
    await _open(tester, _FakeConn(keyHex: ''));

    expect(find.byType(QrImageView), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
  });
}
