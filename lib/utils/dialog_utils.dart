import 'package:flutter/material.dart';
import '../connector/meshcore_connector.dart';
import '../l10n/l10n.dart';
import 'app_logger.dart';

/// Shows a confirmation dialog before disconnecting from the device.
/// Returns true if user confirmed and disconnect completed, false otherwise.
Future<bool> showDisconnectDialog(
  BuildContext context,
  MeshCoreConnector connector,
) async {
  final l10n = context.l10n;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(l10n.dialog_disconnect),
      content: Text(l10n.dialog_disconnectConfirm),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(l10n.common_cancel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(l10n.common_disconnect),
        ),
      ],
    ),
  );

  if (confirmed == true) {
    appLogger.info('Disconnect confirmed from popup', tag: 'Connection');
    await connector.disconnect();
    return true;
  }
  return false;
}

/// Asks before deleting something that cannot be undone. The confirming button
/// is red, as Reboot and Factory Reset are. True only on an explicit confirm.
Future<bool> confirmDelete(
  BuildContext context, {
  required String title,
  required String body,
  String? action,
}) async {
  final l10n = context.l10n;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: Text(l10n.common_cancel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(
            action ?? l10n.common_delete,
            style: const TextStyle(color: Colors.red),
          ),
        ),
      ],
    ),
  );
  return confirmed == true;
}
