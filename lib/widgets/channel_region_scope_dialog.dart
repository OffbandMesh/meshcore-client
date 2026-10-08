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
  late RepeaterChoice? _repeater = widget.repeaters.isEmpty
      ? null
      : widget.repeaters.first;
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

    if (widget.repeaters.isNotEmpty) {
      children.add(
        DropdownButton<RepeaterChoice>(
          isExpanded: true,
          value: _repeater,
          items: [
            for (final r in widget.repeaters)
              DropdownMenuItem(value: r, child: Text(r.name)),
          ],
          onChanged: (v) => setState(() => _repeater = v),
        ),
      );
      children.add(
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const Key('regionScopeDiscover'),
            icon: const Icon(Icons.travel_explore),
            label: Text(l10n.setRegionScope_discover),
            onPressed: widget.service.isLoading ? null : _discover,
          ),
        ),
      );
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
    // then the freshly discovered regions, deduped by name.
    final names = <String>{};
    if (widget.currentScope != null) names.add(widget.currentScope!);
    names.addAll(widget.service.regions.map((r) => r.name));
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
