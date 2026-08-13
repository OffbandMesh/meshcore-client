/// Stock-compatible config import (#576, epic #568).
///
/// Mirrors the stock app's Import Config screen, including the detail that
/// **nothing is checked by default**. Export opts out, import opts in; that
/// asymmetry is stock's and it is the safe default in each direction.
///
/// The per-section wording is stock's own, because the behavior is stock's own:
/// contacts are upserted, existing channels are never overwritten, and
/// importing an identity is destructive.
library;

import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../l10n/l10n.dart';
import '../models/stock_config.dart';
import '../services/stock_config_export_service.dart' show StockConfigSection;
import '../services/stock_config_import_service.dart';
import '../widgets/adaptive_app_bar_title.dart';
import 'export_config_screen.dart' show sectionLabel;

class ImportConfigScreen extends StatefulWidget {
  const ImportConfigScreen({super.key});

  @override
  State<ImportConfigScreen> createState() => _ImportConfigScreenState();
}

class _ImportConfigScreenState extends State<ImportConfigScreen> {
  StockConfig? _config;

  /// Starts empty: import is opt-in, matching stock.
  final Set<StockConfigSection> _selected = {};
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final connector = context.watch<MeshCoreConnector>();
    final config = _config;

    return Scaffold(
      appBar: AppBar(
        title: AdaptiveAppBarTitle(l10n.importConfig_title),
        centerTitle: true,
        actions: [
          if (config != null)
            IconButton(
              icon: const Icon(Icons.check),
              onPressed: _busy ? null : () => _import(connector, config),
              tooltip: l10n.importConfig_title,
            ),
        ],
      ),
      body: config == null
          ? Center(
              child: FilledButton.icon(
                onPressed: _busy ? null : _pickFile,
                icon: const Icon(Icons.folder_open),
                label: Text(l10n.importConfig_chooseFile),
              ),
            )
          : ListView(
              children: [
                _Banner(text: l10n.importConfig_instruction),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    TextButton(
                      onPressed: () =>
                          setState(() => _selected.addAll(_present(config))),
                      child: Text(l10n.stockConfig_selectAll),
                    ),
                    TextButton(
                      onPressed: () => setState(_selected.clear),
                      child: Text(l10n.stockConfig_deselectAll),
                    ),
                  ],
                ),
                // Only sections the file actually carries are offered.
                for (final section in _present(config))
                  CheckboxListTile(
                    value: _selected.contains(section),
                    controlAffinity: ListTileControlAffinity.trailing,
                    isThreeLine: _noteFor(section) != null,
                    title: Text(_titleFor(section, config, connector)),
                    subtitle: _noteFor(section) == null
                        ? null
                        : Text(_noteFor(section)!),
                    onChanged: (value) => setState(() {
                      if (value ?? false) {
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

  /// The sections this particular file carries. A stock export omits whatever
  /// the exporting user deselected, so an absent section is normal.
  List<StockConfigSection> _present(StockConfig config) {
    return [
      if (config.name != null) StockConfigSection.name,
      if (config.privateKey != null) StockConfigSection.identity,
      if (config.radioSettings != null) StockConfigSection.radioSettings,
      if (config.positionSettings != null) StockConfigSection.positionSettings,
      if (config.otherSettings != null) StockConfigSection.otherSettings,
      if (config.autoAddSettings != null) StockConfigSection.autoAddSettings,
      if (config.channels != null) StockConfigSection.channels,
      if (config.contacts != null) StockConfigSection.contacts,
    ];
  }

  String _titleFor(
    StockConfigSection section,
    StockConfig config,
    MeshCoreConnector connector,
  ) {
    final l10n = context.l10n;
    // Channel and contact counts come from the FILE here, not the device.
    switch (section) {
      case StockConfigSection.channels:
        return l10n.stockConfig_sectionChannels(config.channels?.length ?? 0);
      case StockConfigSection.contacts:
        return l10n.stockConfig_sectionContacts(config.contacts?.length ?? 0);
      default:
        return sectionLabel(context, section, connector);
    }
  }

  String? _noteFor(StockConfigSection section) {
    final l10n = context.l10n;
    switch (section) {
      case StockConfigSection.identity:
        return l10n.importConfig_identityWarning;
      case StockConfigSection.channels:
        return l10n.importConfig_channelsNote;
      case StockConfigSection.contacts:
        return l10n.importConfig_contactsNote;
      default:
        return null;
    }
  }

  Future<void> _pickFile() async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final file = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(label: 'JSON', extensions: ['json']),
        ],
      );
      if (file == null) return;
      final source = utf8.decode(
        await file.readAsBytes(),
        allowMalformed: true,
      );
      final parsed = StockConfig.parse(source);
      if (!mounted) return;
      setState(() {
        _config = parsed;
        _selected.clear();
      });
    } on StockConfigFormatException catch (e) {
      // The exception carries the offending JSON path, so the user is told
      // which part of the file is wrong rather than just "invalid".
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.importConfig_parseFailed(e.toString()))),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.importConfig_parseFailed('$e'))),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import(MeshCoreConnector connector, StockConfig config) async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);

    if (!connector.isConnected) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.importConfig_notConnected)),
      );
      return;
    }
    if (_selected.isEmpty) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.importConfig_nothingSelected)),
      );
      return;
    }
    // Replacing the node identity is irreversible, so it gets its own explicit
    // confirmation rather than riding along with the rest of the selection.
    if (_selected.contains(StockConfigSection.identity)) {
      final confirmed = await _confirmIdentityOverwrite();
      if (confirmed != true) return;
      if (!mounted) return;
    }

    setState(() => _busy = true);
    try {
      final result = await StockConfigImportService(
        connector,
      ).apply(config: config, sections: Set.of(_selected));
      if (!mounted) return;
      await _showResult(result, connector);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool?> _confirmIdentityOverwrite() {
    final l10n = context.l10n;
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.importConfig_confirmIdentityTitle),
        content: Text(l10n.importConfig_confirmIdentityBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.importConfig_cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.importConfig_confirmIdentityAccept),
          ),
        ],
      ),
    );
  }

  /// Shows what actually happened. Skipped channels and unapplied sections are
  /// listed by name with a reason; an import that quietly did less than the
  /// user asked for is the silent failure SAFELANE section 6 forbids.
  Future<void> _showResult(
    StockConfigImportResult result,
    MeshCoreConnector connector,
  ) {
    final l10n = context.l10n;
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.importConfig_resultTitle),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.importConfig_resultCounts(
                  result.contactsWritten,
                  result.channelsAdded,
                ),
              ),
              if (result.failed.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  l10n.importConfig_resultFailedHeading,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                for (final entry in result.failed.entries)
                  Text(
                    l10n.importConfig_entryLine(
                      sectionLabel(context, entry.key, connector),
                      _reasonText(context, entry.value),
                    ),
                  ),
              ],
              if (result.skippedChannels.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  l10n.importConfig_resultSkippedHeading,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                for (final skipped in result.skippedChannels)
                  Text(
                    l10n.importConfig_entryLine(
                      skipped.name,
                      _reasonText(context, skipped.reason),
                    ),
                  ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.importConfig_close),
          ),
        ],
      ),
    );
  }
}

String _reasonText(BuildContext context, StockConfigImportIssue reason) {
  final l10n = context.l10n;
  switch (reason) {
    case StockConfigImportIssue.absentFromFile:
      return l10n.importConfig_reasonAbsentFromFile;
    case StockConfigImportIssue.noReply:
      return l10n.importConfig_reasonNoReply;
    case StockConfigImportIssue.unsupported:
      return l10n.importConfig_reasonUnsupported;
    case StockConfigImportIssue.rejected:
      return l10n.importConfig_reasonRejected;
    case StockConfigImportIssue.alreadyPresent:
      return l10n.importConfig_reasonAlreadyPresent;
    case StockConfigImportIssue.noFreeSlot:
      return l10n.importConfig_reasonNoFreeSlot;
    case StockConfigImportIssue.notWritable:
      return l10n.importConfig_reasonNotWritable;
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.text});

  final String text;

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
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}
