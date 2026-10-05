/// Stock-compatible config export (#574, epic #568).
///
/// Mirrors the stock app's Export Config screen: a list of sections, Select All
/// and Deselect All, and **everything checked by default**. The asymmetry with
/// the import screen (which starts with nothing checked) is deliberate and
/// copied from stock: opt out on the way out, opt in on the way in.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../l10n/l10n.dart';
import '../services/stock_config_export_service.dart';
import '../utils/stock_config_file.dart';
import '../widgets/adaptive_app_bar_title.dart';

class ExportConfigScreen extends StatefulWidget {
  const ExportConfigScreen({super.key});

  @override
  State<ExportConfigScreen> createState() => _ExportConfigScreenState();
}

class _ExportConfigScreenState extends State<ExportConfigScreen> {
  /// Every section starts selected, matching stock.
  final Set<StockConfigSection> _selected = StockConfigSection.values.toSet();
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final connector = context.watch<MeshCoreConnector>();

    return Scaffold(
      appBar: AppBar(
        title: AdaptiveAppBarTitle(l10n.exportConfig_title),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.check),
            onPressed: _busy ? null : () => _export(connector),
            tooltip: l10n.exportConfig_title,
          ),
        ],
      ),
      body: ListView(
        children: [
          _Banner(text: l10n.exportConfig_instruction),
          _Banner(text: l10n.exportConfig_lossyNotice, subdued: true),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TextButton(
                onPressed: () =>
                    setState(() => _selected.addAll(StockConfigSection.values)),
                child: Text(l10n.stockConfig_selectAll),
              ),
              TextButton(
                onPressed: () => setState(_selected.clear),
                child: Text(l10n.stockConfig_deselectAll),
              ),
            ],
          ),
          for (final section in StockConfigSection.values)
            _SectionTile(
              title: sectionLabel(context, section, connector),
              subtitle: _subtitleFor(section, connector),
              selected: _selected.contains(section),
              onChanged: (value) => setState(() {
                if (value) {
                  _selected.add(section);
                } else {
                  _selected.remove(section);
                }
              }),
            ),
        ],
      ),
    );
  }

  String? _subtitleFor(
    StockConfigSection section,
    MeshCoreConnector connector,
  ) {
    final l10n = context.l10n;
    switch (section) {
      case StockConfigSection.name:
        return connector.selfName;
      case StockConfigSection.identity:
        final key = connector.selfPublicKeyHex;
        final abbreviated = key.length > 12
            ? '${key.substring(0, 6)}...${key.substring(key.length - 6)}'
            : key;
        // The private key is never rendered, not even abbreviated.
        return '${l10n.stockConfig_identityWarning}\n'
            '${l10n.stockConfig_publicKeyLabel(abbreviated)}\n'
            '${l10n.stockConfig_privateKeyHidden}';
      case StockConfigSection.radioSettings:
        final freq = connector.currentFreqHz;
        final bw = connector.currentBwHz;
        if (freq == null || bw == null) return null;
        // currentFreqHz is kHz despite its name; currentBwHz really is Hz.
        return '${l10n.settings_frequency}: ${freq / 1000} MHz\n'
            '${l10n.settings_bandwidth}: ${bw / 1000} kHz\n'
            '${l10n.settings_spreadingFactor}: ${connector.currentSf}\n'
            '${l10n.settings_codingRate}: ${connector.currentCr}\n'
            '${l10n.settings_txPower}: ${connector.currentTxPower}';
      case StockConfigSection.positionSettings:
        return '${connector.selfLatitude ?? 0}, ${connector.selfLongitude ?? 0}';
      case StockConfigSection.otherSettings:
        return null;
      case StockConfigSection.autoAddSettings:
        return null;
      case StockConfigSection.channels:
        return l10n.exportConfig_allChannels;
      case StockConfigSection.contacts:
        return l10n.exportConfig_allContacts;
    }
  }

  Future<void> _export(MeshCoreConnector connector) async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);

    if (!connector.isConnected) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.exportConfig_notConnected)),
      );
      return;
    }
    if (_selected.isEmpty) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.exportConfig_nothingSelected)),
      );
      return;
    }

    setState(() => _busy = true);
    try {
      final result = await StockConfigExportService(
        connector,
      ).build(sections: Set.of(_selected));

      // A section the user asked for that could not be gathered is surfaced
      // before the file is written, never dropped quietly.
      if (!result.isComplete) {
        if (!mounted) return;
        final proceed = await _confirmOmissions(result);
        if (proceed != true) return;
      }
      if (!mounted) return;

      await saveStockConfigFile(
        context,
        json: result.config.encode(),
        fileName: stockConfigFileName(connector.selfName, DateTime.now()),
        subject: l10n.exportConfig_shareSubject,
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.exportConfig_failed('$e'))),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool?> _confirmOmissions(StockConfigExportResult result) {
    final l10n = context.l10n;
    final connector = context.read<MeshCoreConnector>();
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.exportConfig_omittedTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final entry in result.omitted.entries)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  _omissionText(
                    context,
                    sectionLabel(context, entry.key, connector),
                    entry.value,
                  ),
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.exportConfig_cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.exportConfig_exportAnyway),
          ),
        ],
      ),
    );
  }
}

String _omissionText(
  BuildContext context,
  String section,
  StockConfigOmission reason,
) {
  final l10n = context.l10n;
  switch (reason) {
    case StockConfigOmission.unsupported:
      return l10n.exportConfig_omittedUnsupported(section);
    case StockConfigOmission.noReply:
      return l10n.exportConfig_omittedNoReply(section);
    case StockConfigOmission.rejected:
      return l10n.exportConfig_omittedRejected(section);
    case StockConfigOmission.unavailable:
      return l10n.exportConfig_omittedUnavailable(section);
  }
}

/// Section titles, shared with the import screen so the two cannot drift.
String sectionLabel(
  BuildContext context,
  StockConfigSection section,
  MeshCoreConnector connector,
) {
  final l10n = context.l10n;
  switch (section) {
    case StockConfigSection.name:
      return l10n.stockConfig_sectionName;
    case StockConfigSection.identity:
      return l10n.stockConfig_sectionIdentity;
    case StockConfigSection.radioSettings:
      return l10n.stockConfig_sectionRadio;
    case StockConfigSection.positionSettings:
      return l10n.stockConfig_sectionPosition;
    case StockConfigSection.otherSettings:
      return l10n.stockConfig_sectionOther;
    case StockConfigSection.autoAddSettings:
      return l10n.stockConfig_sectionAutoAdd;
    case StockConfigSection.channels:
      return l10n.stockConfig_sectionChannels(
        connector.channels.where((c) => !c.isEmpty).length,
      );
    case StockConfigSection.contacts:
      return l10n.stockConfig_sectionContacts(connector.contacts.length);
  }
}

class _SectionTile extends StatelessWidget {
  const _SectionTile({
    required this.title,
    required this.selected,
    required this.onChanged,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final bool selected;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return CheckboxListTile(
      value: selected,
      onChanged: (value) => onChanged(value ?? false),
      controlAffinity: ListTileControlAffinity.trailing,
      isThreeLine: subtitle != null,
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle!),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.text, this.subdued = false});

  final String text;
  final bool subdued;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      color: theme.colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: subdued ? theme.textTheme.bodySmall : null,
            ),
          ),
        ],
      ),
    );
  }
}
