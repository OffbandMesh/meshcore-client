import 'package:flutter/material.dart';

import '../l10n/l10n.dart';

/// A banner at the top of a region-scoped channel chat reminding the user that
/// the channel's messages ride a region. Tapping it opens Set Region Scope so
/// the user can change or clear the scope; the close button dismisses it for the
/// session. Renders nothing when [regionName] is null (unscoped or dismissed).
/// (#1258)
class RegionScopeBanner extends StatelessWidget {
  const RegionScopeBanner({
    super.key,
    required this.regionName,
    required this.onTap,
    required this.onDismiss,
  });

  final String? regionName;
  final VoidCallback onTap;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final name = regionName;
    if (name == null) return const SizedBox.shrink();
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.secondaryContainer,
      child: InkWell(
        key: const Key('regionScopeBannerBody'),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          child: Row(
            children: [
              Icon(
                Icons.travel_explore,
                size: 20,
                color: scheme.onSecondaryContainer,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  l10n.setRegionScope_banner(name),
                  style: TextStyle(color: scheme.onSecondaryContainer),
                ),
              ),
              IconButton(
                key: const Key('regionScopeBannerDismiss'),
                icon: const Icon(Icons.close, size: 20),
                color: scheme.onSecondaryContainer,
                tooltip: l10n.setRegionScope_bannerDismiss,
                onPressed: onDismiss,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
