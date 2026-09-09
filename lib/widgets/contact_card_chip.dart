import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../l10n/l10n.dart';
import '../models/contact.dart';
import 'add_contact_by_key_dialog.dart';

/// Renders a received contact share card as a tappable Add Contact affordance
/// instead of the raw `<key:type:name>` text. (#610)
///
/// This is the receive half of the exchange. The send half (#611) already
/// emits this format, and the stock app already renders it as a native Add
/// Contact button, so until now sharing worked outbound only: a stock user
/// could add an Offband user from a card, but not the reverse.
///
/// Tapping opens the add dialog seeded with the card, so the user sees the key,
/// name and type before anything is written to the radio. It does NOT add
/// silently: a contact is an identity, and adding one should be a deliberate
/// act with the details visible.
class ContactCardChip extends StatelessWidget {
  const ContactCardChip({super.key, required this.card, required this.style});

  /// The raw matched card text, `<key:type:name>`.
  final String card;

  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final parsed = Contact.fromChannelShare(card);
    final scheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;

    // The regex matched the shape but the parser rejected the contents, e.g. a
    // type outside the documented range. Show the original text rather than a
    // chip that would lie about being addable.
    if (parsed == null) return Text(card, style: style);

    // Mirrors what stock does: it warned the owner when the contact was
    // already held rather than silently re-adding.
    final known = context.select<MeshCoreConnector, bool>(
      (c) => c.contacts.any((x) => x.publicKeyHex == parsed.publicKeyHex),
    );

    final label = known
        ? l10n.contacts_cardAlreadyAdded(parsed.name)
        : l10n.contacts_cardAddContact(parsed.name);

    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: known
            ? scheme.onSurface.withValues(alpha: 0.08)
            : scheme.primaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            known ? Icons.how_to_reg : Icons.person_add_alt_1,
            size: 15,
            color: known ? scheme.onSurfaceVariant : scheme.onPrimaryContainer,
          ),
          const SizedBox(width: 5),
          Text(
            label,
            style: style.copyWith(
              fontWeight: FontWeight.w500,
              color: known
                  ? scheme.onSurfaceVariant
                  : scheme.onPrimaryContainer,
            ),
          ),
        ],
      ),
    );

    if (known) {
      return Tooltip(
        message: l10n.contacts_cardAlreadyAddedTooltip,
        child: chip,
      );
    }

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => showAddContactByKeyDialog(context, initialKeyText: card),
      child: chip,
    );
  }
}
