import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../l10n/l10n.dart';
import '../models/contact.dart';
import '../models/message.dart';

/// How far a contact identity has actually been confirmed. (#630)
enum ContactVerification {
  /// Added from a bare key. Nothing has confirmed it on air.
  keyOnly,

  /// A message with this contact went through. That is cryptographic proof
  /// the holder of the matching private key is live and reachable, because
  /// direct messages are encrypted with an ECDH secret derived from this
  /// contact key, and the ACK is computed over the decrypted plaintext
  /// (firmware `BaseChatMesh.cpp:442,451`). It does NOT prove the person is
  /// who the name claims: names are display, keys are identity.
  keyConfirmed,

  /// A signed advert has been received. Strongest state: the node itself
  /// asserted its name, type and position, and the raw advert is stored, so
  /// the contact can also be re-shared.
  advertVerified,
}

/// Resolves the verification state for [contact].
///
/// The advert check is first because it is free and covers most contacts; only
/// an unverified contact pays for a message scan, which keeps this cheap on a
/// long contact list.
ContactVerification resolveContactVerification(
  Contact contact,
  MeshCoreConnector connector,
) {
  if (contact.isAdvertVerified) return ContactVerification.advertVerified;
  final delivered = connector
      .getMessages(contact)
      .any((m) => m.status == MessageStatus.delivered);
  return delivered
      ? ContactVerification.keyConfirmed
      : ContactVerification.keyOnly;
}

/// A small, deliberately calm indicator of how far a contact is confirmed.
///
/// Owner steer (#630): a green check for fully verified and a different icon
/// otherwise. Explicitly NOT amber and NOT a hazard glyph, because nothing is
/// wrong with a key-added contact. The scale reads as "how much we know",
/// never as "how risky".
class ContactVerificationBadge extends StatelessWidget {
  const ContactVerificationBadge({
    super.key,
    required this.contact,
    this.size = 15,
  });

  final Contact contact;
  final double size;

  @override
  Widget build(BuildContext context) {
    final state = resolveContactVerification(
      contact,
      context.read<MeshCoreConnector>(),
    );
    final scheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;

    final (IconData icon, Color color, String tooltip) = switch (state) {
      ContactVerification.advertVerified => (
        Icons.verified,
        // The one deliberately positive colour in the set.
        Colors.green,
        l10n.contacts_verifiedByAdvert,
      ),
      ContactVerification.keyConfirmed => (
        Icons.check_circle_outline,
        scheme.onSurfaceVariant,
        l10n.contacts_verifiedByMessage,
      ),
      ContactVerification.keyOnly => (
        Icons.key_outlined,
        scheme.onSurfaceVariant,
        l10n.contacts_verifiedKeyOnly,
      ),
    };

    return Tooltip(
      message: tooltip,
      child: Icon(icon, size: size, color: color),
    );
  }
}
