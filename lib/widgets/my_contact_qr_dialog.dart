import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../connector/meshcore_protocol.dart';
import '../helpers/snack_bar_builder.dart';
import '../l10n/l10n.dart';
import '../models/contact.dart';
import 'qr_code_display.dart';

/// Shows this device's own identity as a scannable QR plus a copyable link.
/// (#629)
///
/// This is the fast, definitive way to hand someone your identity: it carries
/// the public key itself, so it cannot fail on a name mismatch and it does not
/// ask them to wait for an advert. It also costs the mesh no airtime, which
/// asking for a couple of flood adverts does.
///
/// Rendering works on every platform, which matters on desktop: put this on
/// screen and the other person scans it with their phone.
Future<void> showMyContactQrDialog(BuildContext context) {
  final connector = Provider.of<MeshCoreConnector>(context, listen: false);
  final keyHex = connector.selfPublicKeyHex;

  // Without a connection we do not know our own key, so there is nothing
  // truthful to render.
  if (keyHex.length != pubKeySize * 2) {
    showDismissibleSnackBar(
      context,
      content: Text(context.l10n.contacts_qrNeedsConnection),
    );
    return Future<void>.value();
  }

  final uri = Contact.buildShareUri(
    publicKeyHex: keyHex,
    name: connector.selfName ?? '',
    // This device is a companion.
    type: advTypeChat,
  );

  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(dialogContext.l10n.contacts_myContactQr),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            QrCodeDisplay(
              data: uri,
              instructions: dialogContext.l10n.contacts_myContactQrInstructions,
            ),
            const SizedBox(height: 8),
            SelectableText(
              uri,
              style: Theme.of(dialogContext).textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                color: Theme.of(dialogContext).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: uri));
            if (!dialogContext.mounted) return;
            showDismissibleSnackBar(
              dialogContext,
              content: Text(dialogContext.l10n.contacts_contactLinkCopied),
            );
          },
          icon: const Icon(Icons.copy),
          label: Text(dialogContext.l10n.common_copy),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(dialogContext.l10n.common_close),
        ),
      ],
    ),
  );
}
