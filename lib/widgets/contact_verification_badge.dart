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
/// This runs from a widget `build` inside a contact `ListView`, so it does as
/// little as possible:
///
/// 1. An advert-verified contact returns immediately on a single integer
///    comparison. That is most contacts, and no message list is touched.
/// 2. Only a key-only contact scans, and it scans **newest first**, because a
///    delivered message is overwhelmingly likely to be recent.
///
/// A `lastMessageAt == epoch` shortcut was considered and **rejected**:
/// `_setContactLastMessageAt` maintains that field only for `advTypeChat`, so
/// a key-added repeater that had been messaged would have reported the wrong
/// badge. A cheap wrong answer is worse than a slightly slower right one.
///
/// Remaining worst case is a key-only contact carrying many messages of which
/// none ever delivered. If that shows up in practice the fix is a cached flag
/// set once on first delivery, not a bounded scan, which could misreport.
ContactVerification resolveContactVerification(
  Contact contact,
  MeshCoreConnector connector,
) {
  if (contact.isAdvertVerified) return ContactVerification.advertVerified;
  final messages = connector.getMessages(contact);
  for (var i = messages.length - 1; i >= 0; i--) {
    if (messages[i].status == MessageStatus.delivered) {
      return ContactVerification.keyConfirmed;
    }
  }
  return ContactVerification.keyOnly;
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
