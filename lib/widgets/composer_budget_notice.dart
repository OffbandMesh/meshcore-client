import 'package:flutter/material.dart';

import '../connector/meshcore_connector.dart';
import '../connector/meshcore_protocol.dart';
import '../l10n/l10n.dart';

/// Explains a composer whose byte budget is too small to carry a message.
///
/// #592 was reported twice as "the keyboard doesn't respond". It was not an
/// input bug: the byte budget had collapsed to 0, so the length limiter
/// rejected every keystroke while the field still focused and blinked. Nothing
/// on screen said why.
///
/// This is a persistent inline notice rather than a toast on purpose. The
/// condition is a *state* that lasts as long as the link does, not an event, so
/// a transient snackbar would scroll away and leave the same dead field behind.
/// SAFELANE 6 requires a user-facing error to persist; sitting directly above
/// the composer it also lands where the confusion is (#684).
///
/// Renders nothing when the budget is healthy, so both composers can include it
/// unconditionally.
class ComposerBudgetNotice extends StatelessWidget {
  /// The composer's computed limit, from `maxChannelMessageBytes` or
  /// `maxContactMessageBytes`.
  final int maxBytes;

  /// Transport in use, so the cause can be named plainly instead of described
  /// as generic failure.
  final MeshCoreTransportType transport;

  const ComposerBudgetNotice({
    super.key,
    required this.maxBytes,
    required this.transport,
  });

  @override
  Widget build(BuildContext context) {
    if (isComposerBudgetUsable(maxBytes)) return const SizedBox.shrink();

    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;

    // A budget of 0 blocks every keystroke; 1-15 accepts input but cannot carry
    // a sentence. The user needs those described differently: the first is
    // "you cannot send", the second is "you have almost no room".
    final title = maxBytes <= 0
        ? l10n.composerBudgetBlockedTitle
        : l10n.composerBudgetLimitedTitle(maxBytes);

    final cause = transport == MeshCoreTransportType.bluetooth
        ? l10n.composerBudgetBluetoothCause
        : l10n.composerBudgetGenericCause;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: scheme.errorContainer,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 18, color: scheme.onErrorContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: scheme.onErrorContainer,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  cause,
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onErrorContainer,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
