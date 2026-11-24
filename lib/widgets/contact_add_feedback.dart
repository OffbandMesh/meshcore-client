import 'package:flutter/material.dart';

import '../connector/meshcore_connector.dart';
import '../helpers/snack_bar_builder.dart';
import '../helpers/stale_contacts.dart';
import '../l10n/l10n.dart';
import '../models/contact.dart';
import '../screens/prune_contacts_screen.dart';

/// Tells the user how a contact add ended. A refusal or no reply stays on
/// screen until dismissed: the contact was not added, and they have to know
/// why. (#1028)
void showContactAddResult(
  BuildContext context,
  ContactAddResult result,
  String name,
) {
  final l10n = context.l10n;
  final shown = result.name ?? name;
  final String text;
  switch (result.outcome) {
    case ContactAddOutcome.added:
      text = l10n.contacts_addByKeyAdded(shown);
    case ContactAddOutcome.refused:
      text = result.radioFull
          ? l10n.contacts_addRadioFull(shown)
          : l10n.contacts_addRadioRefused(shown, result.errCode ?? -1);
    case ContactAddOutcome.full:
      text = l10n.contacts_addRadioFull(shown);
    case ContactAddOutcome.noReply:
      text = l10n.contacts_addNoReply(shown);
    case ContactAddOutcome.notConnected:
      text = l10n.contacts_addByKeyFailed;
  }
  showDismissibleSnackBar(context, content: Text(text), persist: !result.added);
}

/// Text for a removal the radio did not confirm.
String contactRemoveFailureText(
  BuildContext context,
  ContactRemoveResult result,
  String name,
) => result.outcome == ContactRemoveOutcome.refused
    ? context.l10n.contacts_removeRefused(name, result.errCode ?? -1)
    : context.l10n.contacts_removeNoReply(name);

/// Runs [add]. When the radio is full it was not sent: the firmware would
/// overwrite a contact on its own, so the user chooses first what comes off
/// the radio, and [add] runs once more after that removal is confirmed.
/// Cancelling sends nothing. Owner decision 2026-11-24. (#1028)
Future<void> addContactWithFeedback(
  BuildContext context,
  MeshCoreConnector connector,
  String name,
  Future<ContactAddResult?> Function() add,
) async {
  var result = await add();
  if (result == null || !context.mounted) return;
  if (result.outcome == ContactAddOutcome.full) {
    final shown = result.name ?? name;
    if (!await makeRoomForContact(context, connector, shown)) return;
    if (!context.mounted) return;
    result = await add();
    if (result == null || !context.mounted) return;
  }
  showContactAddResult(context, result, name);
}

/// Adds a contact heard on the mesh and reports the outcome.
Future<void> importDiscoveredContactWithFeedback(
  BuildContext context,
  MeshCoreConnector connector,
  Contact contact,
) => addContactWithFeedback(
  context,
  connector,
  contact.name,
  () => connector.importDiscoveredContact(contact),
);

enum _MakeRoom { removeSuggested, prune }

/// Asks which contact comes off the full radio so [name] can be added, and
/// removes it. True once the radio has confirmed a removal.
Future<bool> makeRoomForContact(
  BuildContext context,
  MeshCoreConnector connector,
  String name,
) async {
  final l10n = context.l10n;
  final suggested = connector.contactToMakeRoom();
  final choice = await showDialog<_MakeRoom>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(l10n.contacts_makeRoomTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.contacts_makeRoomBody(name)),
          const SizedBox(height: 8),
          if (suggested != null)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.person_remove_outlined),
              title: Text(l10n.contacts_makeRoomRemove(suggested.name)),
              subtitle: Text(
                l10n.contacts_lastHeardDays(
                  DateTime.now().difference(lastHeard(suggested)).inDays,
                ),
              ),
              onTap: () =>
                  Navigator.pop(dialogContext, _MakeRoom.removeSuggested),
            ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.cleaning_services_outlined),
            title: Text(l10n.contacts_pruneTitle),
            onTap: () => Navigator.pop(dialogContext, _MakeRoom.prune),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: Text(l10n.common_cancel),
        ),
      ],
    ),
  );
  if (!context.mounted || choice == null) return false;

  if (choice == _MakeRoom.prune) {
    final removed = await Navigator.push<int>(
      context,
      MaterialPageRoute(builder: (_) => const PruneContactsScreen()),
    );
    return (removed ?? 0) > 0;
  }

  final result = await connector.removeContactFromRadio(suggested!);
  if (result.removed) return true;
  if (context.mounted) {
    showDismissibleSnackBar(
      context,
      content: Text(contactRemoveFailureText(context, result, suggested.name)),
      persist: true,
    );
  }
  return false;
}
