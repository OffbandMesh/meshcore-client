import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../l10n/l10n.dart';
import '../services/region_discovery_service.dart';

/// A repeater the user can discover regions from (name + 32-byte key).
class RepeaterChoice {
  const RepeaterChoice({required this.name, required this.pubKey});
  final String name;
  final Uint8List pubKey;
}

/// Pick the flood region a channel's outgoing messages ride (Feature #812,
/// Epic #815). Discovers regions from a chosen repeater (via the injected
/// [service]) and lets the user select one, or None to leave the channel
/// unscoped. Persisting the choice is the caller's job, via [onSave].
class ChannelRegionScopeDialog extends StatefulWidget {
  const ChannelRegionScopeDialog({
    super.key,
    required this.channelName,
    required this.currentScope,
    required this.repeaters,
    required this.service,
    required this.onSave,
  });

  final String channelName;
  final String? currentScope;
  final List<RepeaterChoice> repeaters;
  final RegionDiscoveryService service;
  final Future<void> Function(String? region) onSave;

  @override
  State<ChannelRegionScopeDialog> createState() =>
      _ChannelRegionScopeDialogState();
}

class _ChannelRegionScopeDialogState extends State<ChannelRegionScopeDialog> {
  // Alpha-sorted once (case-insensitive), so the picker is predictable even
  // with many repeater contacts (D1 finding: an unsorted list was unusable).
  late final List<RepeaterChoice> _sortedRepeaters = [...widget.repeaters]
    ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  late RepeaterChoice? _repeater = _sortedRepeaters.isEmpty
      ? null
      : _sortedRepeaters.first;
  String _repeaterFilter = '';
  late String? _selected = widget.currentScope;

  void _discover() {
    final repeater = _repeater;
    if (repeater != null) widget.service.discover(repeater.pubKey);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.setRegionScope_title(widget.channelName)),
      content: SizedBox(
        width: double.maxFinite,
        child: ListenableBuilder(
          listenable: widget.service,
          builder: (context, _) => _content(l10n),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        ElevatedButton(
          key: const Key('regionScopeSave'),
          onPressed: () async {
            await widget.onSave(_selected);
            if (context.mounted) Navigator.of(context).pop();
          },
          child: Text(l10n.setRegionScope_save),
        ),
      ],
    );
  }

  Widget _content(AppLocalizations l10n) {
    final repeaterName = _repeater?.name ?? '';
    final children = <Widget>[];

    if (_sortedRepeaters.isNotEmpty) {
      final filter = _repeaterFilter.toLowerCase();
      final filtered = _sortedRepeaters
          .where((r) => r.name.toLowerCase().contains(filter))
          .toList();
      children.add(
        TextField(
          key: const Key('regionScopeRepeaterSearch'),
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: const Icon(Icons.search),
            hintText: l10n.setRegionScope_searchRepeaters,
          ),
          onChanged: (v) => setState(() => _repeaterFilter = v),
        ),
      );
      children.add(
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 180),
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final r in filtered)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.cell_tower),
                  title: Text(r.name),
                  trailing: identical(r, _repeater)
                      ? const Icon(Icons.check)
                      : null,
                  selected: identical(r, _repeater),
                  onTap: () => setState(() => _repeater = r),
                ),
            ],
          ),
        ),
      );
      children.add(
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const Key('regionScopeDiscover'),
            icon: const Icon(Icons.travel_explore),
            label: Text(l10n.setRegionScope_discover),
            onPressed: (widget.service.isLoading || _repeater == null)
                ? null
                : _discover,
          ),
        ),
      );
      children.add(const Divider(height: 1));
    }

    switch (widget.service.status) {
      case RegionDiscoveryStatus.loading:
        children.add(
          const Padding(
            padding: EdgeInsets.all(12),
            child: Center(child: CircularProgressIndicator()),
          ),
        );
      case RegionDiscoveryStatus.timeout:
        children.add(Text(l10n.discoverRegions_timeout(repeaterName)));
      case RegionDiscoveryStatus.error:
        children.add(
          Text(widget.service.errorMessage ?? l10n.discoverRegions_error),
        );
      case RegionDiscoveryStatus.empty:
        children.add(Text(l10n.discoverRegions_empty(repeaterName)));
      case RegionDiscoveryStatus.idle:
      case RegionDiscoveryStatus.success:
        break;
    }

    children.add(
      ListTile(
        key: const Key('regionScopeNone'),
        title: Text(l10n.setRegionScope_none),
        trailing: _selected == null ? const Icon(Icons.check) : null,
        selected: _selected == null,
        onTap: () => setState(() => _selected = null),
      ),
    );

    // Current scope first (so it stays visible even before a re-discovery),
    // then the discovered regions, alpha-sorted, deduped by name.
    final names = <String>{};
    if (widget.currentScope != null) names.add(widget.currentScope!);
    final discovered = widget.service.regions.map((r) => r.name).toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    names.addAll(discovered);
    for (final name in names) {
      children.add(
        ListTile(
          title: Text(name),
          trailing: _selected == name ? const Icon(Icons.check) : null,
          selected: _selected == name,
          onTap: () => setState(() => _selected = name),
        ),
      );
    }

    return SingleChildScrollView(
      child: Column(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}
