import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../connector/meshcore_protocol.dart';
import '../l10n/l10n.dart';
import '../helpers/snack_bar_builder.dart';
import '../models/contact.dart';
import '../screens/contact_qr_scanner_screen.dart';

/// Adds a contact from an identity alone: a public key, a name and a type.
///
/// This is the manual half of the identity exchange (#628). It exists because
/// a public key is never present in channel traffic, so for anyone who has not
/// recently adverted there is otherwise no way to reach them at all (#620).
///
/// The field also accepts a whole `meshcore://contact/add` link, since that is
/// what someone is most likely to paste, and a QR is only that same link
/// rendered visually.
/// [initialKeyText] seeds the key field, so a scan taken from somewhere else
/// can open this already filled in rather than making the user paste. (#629)
Future<void> showAddContactByKeyDialog(
  BuildContext context, {
  String? initialKeyText,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _AddContactByKeyDialog(initialKeyText: initialKeyText),
  );
}

class _AddContactByKeyDialog extends StatefulWidget {
  const _AddContactByKeyDialog({this.initialKeyText});

  final String? initialKeyText;

  @override
  State<_AddContactByKeyDialog> createState() => _AddContactByKeyDialogState();
}

class _AddContactByKeyDialogState extends State<_AddContactByKeyDialog> {
  final _keyController = TextEditingController();
  final _nameController = TextEditingController();
  int _type = advTypeChat;
  String? _keyError;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    final seed = widget.initialKeyText;
    if (seed != null && seed.isNotEmpty) {
      _keyController.text = seed;
      // Route the seed through the same handler as a paste, so a full link
      // populates name and type instead of sitting there as raw text.
      _onKeyChanged(seed);
    }
  }

  @override
  void dispose() {
    _keyController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  /// Strips whitespace so a key copied across a line break still works.
  String get _cleanedKey =>
      _keyController.text.replaceAll(RegExp(r'\s+'), '').toLowerCase();

  bool get _keyLooksValid => Contact.isValidShareUri(
    Contact.buildShareUri(publicKeyHex: _cleanedKey, name: 'x', type: _type),
  );

  /// If a full contact link was pasted, absorb every field from it rather than
  /// making the user retype a name they already have.
  void _onKeyChanged(String raw) {
    final pasted = Contact.fromShareUri(raw);
    if (pasted != null) {
      setState(() {
        _keyController.value = TextEditingValue(
          text: pasted.publicKeyHex,
          selection: TextSelection.collapsed(
            offset: pasted.publicKeyHex.length,
          ),
        );
        if (pasted.name != 'Unknown') _nameController.text = pasted.name;
        _type = pasted.type;
        _keyError = null;
      });
      return;
    }
    if (_keyError != null) setState(() => _keyError = null);
  }

  Future<void> _scan() async {
    final scanned = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const ContactQrScannerScreen()),
    );
    if (!mounted || scanned == null) return;
    // Route the scan through the same handler as a paste. A QR is only the
    // link rendered visually, so it must not get its own code path.
    _keyController.text = scanned;
    _onKeyChanged(scanned);
  }

  Future<void> _submit() async {
    final l10n = context.l10n;
    if (!_keyLooksValid) {
      setState(() => _keyError = l10n.contacts_publicKeyInvalid);
      return;
    }

    final name = _nameController.text.trim();
    // Round-trip through the share URI so a manually typed contact and a
    // scanned QR produce byte-identical state. One code path, no drift.
    final stub = Contact.fromShareUri(
      Contact.buildShareUri(publicKeyHex: _cleanedKey, name: name, type: _type),
    );
    if (stub == null) {
      setState(() => _keyError = l10n.contacts_publicKeyInvalid);
      return;
    }

    setState(() => _submitting = true);
    final connector = Provider.of<MeshCoreConnector>(context, listen: false);
    final added = await connector.addContactByKey(stub);
    if (!mounted) return;

    Navigator.of(context).pop();
    showDismissibleSnackBar(
      context,
      content: Text(
        added
            ? l10n.contacts_addByKeyAdded(stub.name)
            : l10n.contacts_addByKeyFailed,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);

    return AlertDialog(
      title: Text(l10n.contacts_addByKey),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.contacts_addByKeyDescription,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _keyController,
              autofocus: true,
              maxLines: 2,
              minLines: 1,
              decoration: InputDecoration(
                labelText: l10n.contacts_publicKeyLabel,
                helperText: l10n.contacts_publicKeyHelper,
                helperMaxLines: 2,
                errorText: _keyError,
                errorMaxLines: 2,
                border: const OutlineInputBorder(),
                suffixIcon: contactQrScanAvailable
                    ? IconButton(
                        icon: const Icon(Icons.qr_code_scanner),
                        tooltip: l10n.contacts_scanContactQr,
                        onPressed: _submitting ? null : _scan,
                      )
                    : null,
              ),
              onChanged: _onKeyChanged,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _nameController,
              decoration: InputDecoration(
                labelText: l10n.contacts_nameLabel,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<int>(
              initialValue: _type,
              decoration: InputDecoration(
                labelText: l10n.contacts_typeLabel,
                border: const OutlineInputBorder(),
              ),
              items: [
                DropdownMenuItem(
                  value: advTypeChat,
                  child: Text(l10n.contact_typeChat),
                ),
                DropdownMenuItem(
                  value: advTypeRepeater,
                  child: Text(l10n.contact_typeRepeater),
                ),
                DropdownMenuItem(
                  value: advTypeRoom,
                  child: Text(l10n.contact_typeRoom),
                ),
                DropdownMenuItem(
                  value: advTypeSensor,
                  child: Text(l10n.contact_typeSensor),
                ),
              ],
              onChanged: (v) => setState(() => _type = v ?? advTypeChat),
            ),
            const SizedBox(height: 16),
            // Honest about what a key-only add actually gives you. Deliberately
            // informational, not a warning: nothing is wrong with this contact
            // (#630).
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.info_outline,
                  size: 16,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.contacts_addByKeyUnverifiedNote,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: Text(l10n.common_cancel),
        ),
        FilledButton(
          onPressed: _submitting ? null : _submit,
          child: Text(l10n.common_add),
        ),
      ],
    );
  }
}
