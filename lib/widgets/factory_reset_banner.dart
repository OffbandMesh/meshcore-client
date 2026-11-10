import 'package:flutter/material.dart';

import '../connector/meshcore_connector.dart';
import '../l10n/l10n.dart';

/// Shown above the whole app after a factory reset is sent (#1054). The
/// settings screen is gone by then, because the reset ends the session, so it
/// is reported here and stays until dismissed. Sits in `MaterialApp.builder`,
/// like [ContactSyncShortfallBanner].
class FactoryResetBanner extends StatelessWidget {
  final FactoryResetStatus? status;
  final VoidCallback onDismiss;
  final Widget child;

  const FactoryResetBanner({
    super.key,
    required this.status,
    required this.onDismiss,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final current = status;
    if (current == null) return child;
    return Column(
      children: [
        _banner(context, current),
        Expanded(child: child),
      ],
    );
  }

  Widget _banner(BuildContext context, FactoryResetStatus current) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final failed = current == FactoryResetStatus.deleteFailed;
    final background = failed
        ? scheme.errorContainer
        : scheme.secondaryContainer;
    final foreground = failed
        ? scheme.onErrorContainer
        : scheme.onSecondaryContainer;
    final (title, body) = switch (current) {
      FactoryResetStatus.sentBle => (
        l10n.factoryResetSentTitle,
        l10n.factoryResetSentBleBody,
      ),
      FactoryResetStatus.sent => (
        l10n.factoryResetSentTitle,
        l10n.factoryResetSentBody,
      ),
      FactoryResetStatus.deleteFailed => (
        l10n.factoryResetDeleteFailedTitle,
        l10n.factoryResetDeleteFailedBody,
      ),
    };
    return Material(
      color: background,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 4, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                failed ? Icons.error_outline : Icons.restart_alt,
                color: foreground,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: foreground,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(body, style: TextStyle(color: foreground)),
                  ],
                ),
              ),
              // No tooltip: this sits above the Navigator, where there is no
              // Overlay, and a Tooltip without one blanks the window (#713).
              IconButton(
                icon: Icon(
                  Icons.close,
                  color: foreground,
                  semanticLabel: l10n.common_close,
                ),
                onPressed: onDismiss,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
