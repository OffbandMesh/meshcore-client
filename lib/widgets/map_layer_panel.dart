import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../services/app_settings_service.dart';

/// Map layer toggles for the nav panel.
///
/// The Map view has no list to show, so its panel carries the layer controls
/// that otherwise live in a modal behind the floating button. Pinned on a wide
/// screen these stay visible and the map updates underneath as they are
/// flipped, instead of a dialog covering the thing being filtered.
///
/// The same settings back both surfaces, so a change here shows in the dialog
/// and vice versa.
class MapLayerPanel extends StatelessWidget {
  const MapLayerPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final service = context.watch<AppSettingsService>();
    final settings = service.settings;
    final l10n = context.l10n;
    final theme = Theme.of(context);

    return ListView(
      padding: EdgeInsets.zero,
      children: [
        _sectionHeader(theme, l10n.map_nodeTypes),
        _toggle(
          label: l10n.map_chatNodes,
          icon: Icons.person_outline,
          value: settings.mapShowChatNodes,
          onChanged: service.setMapShowChatNodes,
        ),
        _toggle(
          label: l10n.map_repeaters,
          icon: Icons.cell_tower,
          value: settings.mapShowRepeaters,
          onChanged: service.setMapShowRepeaters,
        ),
        _toggle(
          label: l10n.map_otherNodes,
          icon: Icons.help_outline,
          value: settings.mapShowOtherNodes,
          onChanged: service.setMapShowOtherNodes,
        ),
        const Divider(height: 1),
        _toggle(
          label: l10n.map_alwaysShowNames,
          icon: Icons.label_outline,
          value: settings.mapAlwaysShowNames,
          onChanged: service.setMapAlwaysShowNames,
        ),
        const Divider(height: 1),
        _sectionHeader(theme, l10n.map_filterNodes),
        _toggle(
          label: l10n.map_showDiscoveryContacts,
          icon: Icons.person_search,
          value: settings.mapShowDiscoveryContacts,
          onChanged: service.setMapShowDiscoveryContacts,
        ),
        _toggle(
          label: l10n.map_showGuessedLocations,
          icon: Icons.location_searching,
          value: settings.mapShowGuessedLocations,
          onChanged: service.setMapShowGuessedLocations,
        ),
        _toggle(
          label: l10n.map_showOverlaps,
          icon: Icons.layers,
          value: settings.mapShowOverlaps,
          onChanged: service.setMapShowOverlaps,
        ),
      ],
    );
  }

  Widget _sectionHeader(ThemeData theme, String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        label,
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _toggle({
    required String label,
    required IconData icon,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return SwitchListTile(
      dense: true,
      secondary: Icon(icon, size: 20),
      title: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis),
      value: value,
      onChanged: onChanged,
    );
  }
}
