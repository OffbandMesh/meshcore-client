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

  /// Whether a radio is actually connected.
  ///
  /// Required, and not cosmetic. While disconnected, `_activeTransport` still
  /// reads `bluetooth` (its default) and there is no device, so the frame
  /// budget falls to the same 20-byte floor an unreported MTU produces. Without
  /// this gate the notice would appear on every disconnect and blame the link
  /// for a small packet size when there is no link at all.
  final bool isConnected;

  const ComposerBudgetNotice({
    super.key,
    required this.maxBytes,
    required this.transport,
    required this.isConnected,
  });

  @override
  Widget build(BuildContext context) {
    if (!isConnected) return const SizedBox.shrink();
    if (isComposerBudgetUsable(maxBytes)) return const SizedBox.shrink();

    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;

    // A budget of 0 blocks every keystroke; 1-15 accepts input but cannot carry
    // a sentence. Those are different severities and must not look the same.
    // Zero is a failure: nothing can be sent. Non-zero is a fact about a
    // working link, so it is stated rather than alarmed about - a permanent red
    // banner over a link that genuinely only fits a few characters is noise,
    // and noise is what teaches people to ignore the banner that matters.
    final blocked = maxBytes <= 0;

    final title = blocked
        ? l10n.composerBudgetBlockedTitle
        : l10n.composerBudgetLimitedTitle(maxBytes);

    final cause = transport == MeshCoreTransportType.bluetooth
        ? l10n.composerBudgetBluetoothCause
        : l10n.composerBudgetGenericCause;

    final background = blocked
        ? scheme.errorContainer
        : scheme.secondaryContainer;
    final foreground = blocked
        ? scheme.onErrorContainer
        : scheme.onSecondaryContainer;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: background,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // No semanticLabel on purpose: Icon wraps its glyph in
          // ExcludeSemantics and only announces a label when given one, so an
          // unlabelled icon is correctly decorative here. The two Text children
          // below already carry the whole message to a screen reader, and
          // labelling the icon too would just repeat it.
          Icon(
            blocked ? Icons.error_outline : Icons.info_outline,
            size: 18,
            color: foreground,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: foreground,
                  ),
                ),
                const SizedBox(height: 2),
                Text(cause, style: TextStyle(fontSize: 12, color: foreground)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
