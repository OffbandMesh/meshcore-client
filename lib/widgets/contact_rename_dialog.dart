import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../l10n/l10n.dart';
import '../models/contact.dart';

/// The longest custom name we accept.
///
/// There is no wire constraint: a custom name never leaves this device, so
/// #636's grapheme truncation does not apply to it. The cap exists so a tile
/// stays readable, and it matches the 32-byte on-wire name field closely
/// enough that it will not surprise anyone coming from stock. Counted in
/// characters rather than bytes, since bytes would mean "shorter for CJK" for
/// no reason here. (#750)
const int maxCustomNameLength = 32;

/// Lets the user give a contact their own name, the way stock MeshCore's
/// CUSTOM NAME field does. (#750)
///
/// The node keeps its own name underneath, and adverts keep that up to date,
/// so renaming never costs accuracy. Clearing reverts to whatever the node
/// last told us, which may be newer than what was shown when the rename
/// happened.
Future<void> showContactRenameDialog(BuildContext context, Contact contact) =>
    showDialog<void>(
      context: context,
      builder: (_) => _ContactRenameDialog(contact: contact),
    );

class _ContactRenameDialog extends StatefulWidget {
  const _ContactRenameDialog({required this.contact});

  final Contact contact;

  @override
  State<_ContactRenameDialog> createState() => _ContactRenameDialogState();
}

class _ContactRenameDialogState extends State<_ContactRenameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.contact.customName ?? '',
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _tooLong => _controller.text.characters.length > maxCustomNameLength;

  Future<void> _save() async {
    if (_tooLong) return;
    final connector = context.read<MeshCoreConnector>();
    final navigator = Navigator.of(context);
    // An empty or whitespace-only field is a clear, not a blank name.
    // Normalized HERE as well as in the connector and the store, so none of
    // the three is load-bearing on its own and the dialog never hands a blank
    // downstream to be cleaned up. (T29, T30)
    final typed = _controller.text;
    await connector.setContactCustomName(
      widget.contact.publicKeyHex,
      typed.trim().isEmpty ? null : typed,
    );
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

    return AlertDialog(
      title: Text(l10n.contact_renameTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            decoration: InputDecoration(
              hintText: l10n.contact_renameHint,
              // Present only while the input is actually too long, absent when
              // it is valid. (T27)
              errorText: _tooLong
                  ? l10n.contact_renameTooLong(maxCustomNameLength)
                  : null,
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 12),
          // What the node calls itself, shown at the moment of the decision
          // and only when it differs from what is typed, so the user can see
          // the name they are overriding rather than having to remember it.
          // (T25, T26)
          if (_controller.text.trim() != widget.contact.receivedName)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                l10n.contact_nodeCallsItself(widget.contact.receivedName),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          // Says plainly that this is local and that accuracy is not lost, so
          // nobody has to guess what renaming costs them.
          Text(
            l10n.contact_renameExplain,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () async {
            final connector = context.read<MeshCoreConnector>();
            final navigator = Navigator.of(context);
            await connector.setContactCustomName(
              widget.contact.publicKeyHex,
              null,
            );
            navigator.pop();
          },
          child: Text(l10n.contact_renameClear),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.common_cancel),
        ),
        FilledButton(
          onPressed: _tooLong ? null : _save,
          child: Text(l10n.common_save),
        ),
      ],
    );
  }
}
