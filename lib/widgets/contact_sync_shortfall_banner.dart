import 'package:flutter/material.dart';

import '../connector/meshcore_connector.dart';
import '../l10n/l10n.dart';

/// Shown above the whole app when a full contact sync delivered fewer contacts
/// than the radio reported (#668). The banner stays until dismissed. When the
/// automatic retry was also short, a modal asks whether to keep the saved
/// contacts (the default) or accept the radio's shorter list.
///
/// SAFELANE §6: the short sync that silently replaced 350 saved contacts with
/// 106 (#660) must now be loud. Sits in `MaterialApp.builder`, above the
/// Navigator, so the modal is drawn here rather than pushed as a route.
class ContactSyncShortfallBanner extends StatelessWidget {
  final ContactSyncShortfall? shortfall;
  final bool decisionPending;
  final int undeliveredCount;
  final VoidCallback onDismiss;
  final VoidCallback onKeep;
  final VoidCallback onUseRadio;
  final Widget child;

  const ContactSyncShortfallBanner({
    super.key,
    required this.shortfall,
    required this.decisionPending,
    required this.undeliveredCount,
    required this.onDismiss,
    required this.onKeep,
    required this.onUseRadio,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final current = shortfall;
    if (current == null && !decisionPending) return child;

    final content = current == null
        ? child
        : Column(
            children: [
              _banner(context, current),
              Expanded(child: child),
            ],
          );
    if (!decisionPending) return content;

    return Stack(
      children: [
        content,
        const ModalBarrier(dismissible: false, color: Colors.black54),
        Center(child: _decision(context, current?.received ?? 0)),
      ],
    );
  }

  Widget _banner(BuildContext context, ContactSyncShortfall current) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final declared = current.declared;
    final body = declared == null
        ? l10n.contactSyncShortfallBodyNoTotal(current.received)
        : l10n.contactSyncShortfallBody(declared, current.received);
    return Material(
      color: scheme.errorContainer,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 4, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.sync_problem, color: scheme.onErrorContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.contactSyncShortfallTitle,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: scheme.onErrorContainer,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      body,
                      style: TextStyle(color: scheme.onErrorContainer),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: l10n.common_close,
                icon: Icon(Icons.close, color: scheme.onErrorContainer),
                onPressed: onDismiss,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _decision(BuildContext context, int received) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.contactSyncDecisionTitle),
      content: Text(l10n.contactSyncDecisionBody(received, undeliveredCount)),
      actions: [
        TextButton(
          onPressed: onUseRadio,
          child: Text(l10n.contactSyncUseRadio),
        ),
        FilledButton(
          autofocus: true,
          onPressed: onKeep,
          child: Text(l10n.contactSyncKeep),
        ),
      ],
    );
  }
}
