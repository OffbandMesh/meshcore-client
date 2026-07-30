import 'package:flutter/material.dart';

import '../l10n/l10n.dart';

/// A persistent, non-dismissable banner shown above the whole app when the
/// storage layer failed to open (#385).
///
/// SAFELANE §6: a storage failure must be loud and stay visible, not a 4s
/// toast, and never a silent empty screen. When [show] is false this is a
/// transparent pass-through and adds no layout.
class StorageUnavailableBanner extends StatelessWidget {
  final bool show;
  final Widget child;

  const StorageUnavailableBanner({
    super.key,
    required this.show,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    if (!show) return child;

    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Material(
          color: scheme.errorContainer,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    color: scheme.onErrorContainer,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          context.l10n.storageUnavailableTitle,
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: scheme.onErrorContainer,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          context.l10n.storageUnavailableBody,
                          style: TextStyle(color: scheme.onErrorContainer),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Expanded(child: child),
      ],
    );
  }
}
