import 'package:flutter/material.dart';

import '../helpers/snack_bar_builder.dart';
import '../l10n/l10n.dart';
import '../models/contact.dart';
import '../widgets/qr_scanner_widget.dart';

/// Scans a contact QR and pops the raw `meshcore://contact/add` string. (#629)
///
/// A contact QR is only that URI rendered visually, so this validates with the
/// same [Contact.isValidShareUri] the paste path uses. There is no second
/// format and no second parser.
class ContactQrScannerScreen extends StatelessWidget {
  const ContactQrScannerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.contacts_scanContactQr),
        centerTitle: true,
      ),
      body: QrScannerWidget(
        instructions: context.l10n.contacts_scanContactQrInstructions,
        validator: Contact.isValidShareUri,
        onScanned: (data) => Navigator.of(context).pop(data),
        onValidationFailed: (_) => showDismissibleSnackBar(
          context,
          content: Text(context.l10n.contacts_invalidContactQr),
        ),
      ),
    );
  }
}
