import 'package:flutter/material.dart';

import '../connector/meshcore_connector.dart';
import '../helpers/snack_bar_builder.dart';
import '../l10n/l10n.dart';
import '../models/contact.dart';

/// Tells the user how a contact add ended. A refusal or no reply stays on
/// screen until dismissed: the contact was not added, and they have to know
/// why. (#1028)
void showContactAddResult(
  BuildContext context,
  ContactAddResult result,
  String name,
) {
  final l10n = context.l10n;
  final String text;
  switch (result.outcome) {
    case ContactAddOutcome.added:
      text = l10n.contacts_addByKeyAdded(name);
    case ContactAddOutcome.refused:
      text = result.radioFull
          ? l10n.contacts_addRadioFull(name)
          : l10n.contacts_addRadioRefused(name, result.errCode ?? -1);
    case ContactAddOutcome.noReply:
      text = l10n.contacts_addNoReply(name);
    case ContactAddOutcome.notConnected:
      text = l10n.contacts_addByKeyFailed;
  }
  showDismissibleSnackBar(context, content: Text(text), persist: !result.added);
}

/// Adds a contact heard on the mesh and reports the outcome.
Future<void> importDiscoveredContactWithFeedback(
  BuildContext context,
  MeshCoreConnector connector,
  Contact contact,
) async {
  final result = await connector.importDiscoveredContact(contact);
  if (!context.mounted) return;
  showContactAddResult(context, result, contact.name);
}
