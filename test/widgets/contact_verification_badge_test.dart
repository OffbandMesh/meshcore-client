// Verification-state tests (#630).
//
// The three states are not cosmetic. advertVerified means the node itself
// asserted its identity in a signed advert. keyConfirmed means a message went
// through, which only works with the matching private key. keyOnly means
// someone typed a key and nothing has confirmed it on air.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/models/message.dart';
import 'package:meshcore_open/widgets/contact_verification_badge.dart';

const _key = '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff';

Contact _contact({required DateTime lastSeen}) => Contact(
  publicKey: hex2Uint8List(_key),
  name: 'Bob',
  type: advTypeChat,
  pathLength: -1,
  path: Uint8List(0),
  lastSeen: lastSeen,
);

Contact _keyOnly() =>
    _contact(lastSeen: DateTime.fromMillisecondsSinceEpoch(0));
Contact _adverted() => _contact(lastSeen: DateTime(2026, 9, 6, 12));

Message _msg(MessageStatus status) => Message(
  senderKey: hex2Uint8List(_key),
  text: 'hi',
  isOutgoing: true,
  timestamp: DateTime(2026, 9, 6),
  status: status,
);

class _Conn extends MeshCoreConnector {
  _Conn(this.messages);
  final List<Message> messages;

  @override
  List<Message> getMessages(Contact contact) => messages;
}

void main() {
  group('Contact.isAdvertVerified (#630)', () {
    test('a key-only contact carries the epoch and is not advert-verified', () {
      expect(_keyOnly().isAdvertVerified, isFalse);
    });

    test('any real advert timestamp counts as verified', () {
      expect(_adverted().isAdvertVerified, isTrue);
    });

    test('the parser output is unverified by construction', () {
      // Ties the model getter to what fromShareUri actually produces, so the
      // two cannot drift.
      final parsed = Contact.fromShareUri(
        'meshcore://contact/add?name=Bob&public_key=$_key&type=1',
      )!;
      expect(parsed.isAdvertVerified, isFalse);
    });
  });

  group('resolveContactVerification (#630)', () {
    test('an adverted contact is advertVerified even with no messages', () {
      expect(
        resolveContactVerification(_adverted(), _Conn(const [])),
        ContactVerification.advertVerified,
      );
    });

    test('an advert wins over message history', () {
      // The advert is strictly stronger: it is signed and it stores the raw
      // packet that makes the contact re-shareable.
      expect(
        resolveContactVerification(
          _adverted(),
          _Conn([_msg(MessageStatus.delivered)]),
        ),
        ContactVerification.advertVerified,
      );
    });

    test('a key-only contact with no traffic is keyOnly', () {
      expect(
        resolveContactVerification(_keyOnly(), _Conn(const [])),
        ContactVerification.keyOnly,
      );
    });

    test('a delivered message upgrades a key-only contact to keyConfirmed', () {
      expect(
        resolveContactVerification(
          _keyOnly(),
          _Conn([_msg(MessageStatus.sent), _msg(MessageStatus.delivered)]),
        ),
        ContactVerification.keyConfirmed,
      );
    });

    test('unacked traffic does NOT confirm the key', () {
      // sent means it left the radio. failed and pending prove nothing at all.
      // Only delivered means the far end produced the right ACK, which needs
      // the plaintext, which needs the matching private key.
      for (final s in [
        MessageStatus.pending,
        MessageStatus.sent,
        MessageStatus.failed,
      ]) {
        expect(
          resolveContactVerification(_keyOnly(), _Conn([_msg(s)])),
          ContactVerification.keyOnly,
          reason: '$s must not count as confirmation',
        );
      }
    });
  });

  group('ContactVerificationBadge rendering (#630)', () {
    Future<void> pump(WidgetTester tester, Contact c, _Conn conn) =>
        tester.pumpWidget(
          ChangeNotifierProvider<MeshCoreConnector>.value(
            value: conn,
            child: MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(body: ContactVerificationBadge(contact: c)),
            ),
          ),
        );

    testWidgets('advert-verified shows the green check', (tester) async {
      await pump(tester, _adverted(), _Conn(const []));
      final icon = tester.widget<Icon>(find.byType(Icon));
      expect(icon.icon, Icons.verified);
      expect(icon.color, Colors.green);
    });

    testWidgets('key-confirmed shows a neutral check, not green', (
      tester,
    ) async {
      await pump(tester, _keyOnly(), _Conn([_msg(MessageStatus.delivered)]));
      final icon = tester.widget<Icon>(find.byType(Icon));
      expect(icon.icon, Icons.check_circle_outline);
      expect(icon.color, isNot(Colors.green));
    });

    testWidgets('key-only shows a muted key and nothing alarming', (
      tester,
    ) async {
      await pump(tester, _keyOnly(), _Conn(const []));
      final icon = tester.widget<Icon>(find.byType(Icon));
      expect(icon.icon, Icons.key_outlined);
      // Owner steer: no amber, no hazard glyph. Nothing is wrong with this
      // contact, it is just less confirmed.
      expect(icon.icon, isNot(Icons.warning));
      expect(icon.icon, isNot(Icons.warning_amber));
      expect(icon.icon, isNot(Icons.error_outline));
      expect(icon.color, isNot(Colors.amber));
      expect(icon.color, isNot(Colors.red));
    });
  });
}
