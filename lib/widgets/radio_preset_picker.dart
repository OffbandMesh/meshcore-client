import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../models/radio_preset.dart';
import '../services/radio_preset_service.dart';

/// The regional preset picker (#729): presets grouped by region under
/// non-selectable headers, each labelled with its source, plus a status line
/// saying where the list came from (and any refresh failure) with a refresh
/// button. Used by the companion Radio Settings form and the remote-node
/// settings screen.
class RadioPresetPicker extends StatelessWidget {
  const RadioPresetPicker({
    super.key,
    required this.service,
    required this.presets,
    required this.selectedId,
    required this.onSelected,
  });

  final RadioPresetService service;

  /// The presets to offer, already filtered and in display order (grouped
  /// by region).
  final List<RadioPreset> presets;
  final String? selectedId;
  final ValueChanged<RadioPreset> onSelected;

  static const _regionHeaderPrefix = 'region:';

  RadioPreset? _byId(String? id) =>
      id == null ? null : presets.where((p) => p.id == id).firstOrNull;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final selected = _byId(selectedId)?.id;
    final items = <DropdownMenuItem<String>>[];
    String? region;
    for (final preset in presets) {
      if (preset.region != region) {
        region = preset.region;
        items.add(
          DropdownMenuItem<String>(
            value: '$_regionHeaderPrefix$region',
            enabled: false,
            child: Text(
              region,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        );
      }
      items.add(
        DropdownMenuItem<String>(
          value: preset.id,
          child: Padding(
            padding: const EdgeInsetsDirectional.only(start: 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(preset.title, overflow: TextOverflow.ellipsis),
                ),
                const SizedBox(width: 8),
                Text(
                  switch (preset.source) {
                    RadioPresetSource.meshcore =>
                      l10n.settings_presetSourceMeshCore,
                    RadioPresetSource.offband =>
                      l10n.settings_presetSourceOffband,
                  },
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DropdownButtonFormField<String>(
          key: ValueKey<String?>(selected),
          initialValue: selected,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: l10n.settings_presets,
            border: const OutlineInputBorder(),
          ),
          selectedItemBuilder: (context) => [
            for (final item in items)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: Text(
                  _byId(item.value)?.title ?? '',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          items: items,
          onChanged: (id) {
            final preset = _byId(id);
            if (preset != null) onSelected(preset);
          },
        ),
        _PresetStatus(service: service),
      ],
    );
  }
}

/// Where the list came from, and any refresh failure, kept on screen until
/// the next successful refresh.
class _PresetStatus extends StatelessWidget {
  const _PresetStatus({required this.service});

  final RadioPresetService service;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final String text;
    Color? color;
    if (service.refreshing) {
      text = l10n.settings_presetsUpdating;
    } else if (service.refreshError != null) {
      text = l10n.settings_presetsUpdateFailed;
      color = theme.colorScheme.error;
    } else if (service.lastRefreshed != null) {
      text = l10n.settings_presetsUpdatedAt(
        MaterialLocalizations.of(
          context,
        ).formatMediumDate(service.lastRefreshed!.toLocal()),
      );
    } else {
      text = l10n.settings_presetsBundled;
    }
    return Row(
      children: [
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(
              color: color ?? theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        IconButton(
          tooltip: l10n.settings_presetsRefresh,
          onPressed: service.refreshing ? null : service.refresh,
          icon: service.refreshing
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.refresh),
        ),
      ],
    );
  }
}
