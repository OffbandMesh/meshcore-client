import 'package:flutter/material.dart';

import '../../models/config_catalog.dart';
import '../../services/config_source_service.dart';
import '../../services/observer_config_service.dart';
import 'config_profile_preview_screen.dart';

/// Entry screen for importing a config profile (#407): browse the curated
/// catalog or point at any source URL, then hand a fetched profile to the
/// preview/apply screen (#406).
class ConfigProfileImportScreen extends StatefulWidget {
  const ConfigProfileImportScreen({super.key, required this.service});

  /// The connected observer's config service, threaded to the preview screen.
  final ObserverConfigService service;

  @override
  State<ConfigProfileImportScreen> createState() =>
      _ConfigProfileImportScreenState();
}

class _ConfigProfileImportScreenState extends State<ConfigProfileImportScreen> {
  final _source = ConfigSourceService();
  final _urlController = TextEditingController();

  List<CatalogEntry> _entries = const [];
  int _skipped = 0;
  String? _catalogLabel; // which catalog is shown (default vs custom)
  String? _error;
  bool _loading = true;
  bool _busy = false; // fetching a single profile before navigating

  @override
  void initState() {
    super.initState();
    _loadCatalog(kDefaultCatalogUrl, label: 'Offband catalog');
  }

  @override
  void dispose() {
    _urlController.dispose();
    _source.dispose();
    super.dispose();
  }

  Future<void> _loadCatalog(String url, {required String label}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final catalog = await _source.fetchCatalog(url);
      if (!mounted) return;
      setState(() {
        _entries = catalog.published;
        _skipped = catalog.skippedEntries;
        _catalogLabel = label;
      });
    } catch (e) {
      if (mounted) setState(() => _error = _msg(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Handle the URL box: a catalog URL replaces the list; a single-profile URL
  /// goes straight to preview.
  Future<void> _openUrl() async {
    final raw = _urlController.text.trim();
    if (raw.isEmpty) return;
    setState(() => _error = null);
    final ResolvedSource resolved;
    try {
      resolved = resolveSourceUrl(raw);
    } catch (e) {
      setState(() => _error = _msg(e));
      return;
    }
    if (resolved.kind == SourceKind.catalog) {
      await _loadCatalog(resolved.url, label: 'Custom catalog');
    } else {
      await _openProfile(resolved.url);
    }
  }

  Future<void> _openProfile(String url) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final profile = await _source.fetchProfile(url);
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ConfigProfilePreviewScreen(
            profile: profile,
            service: widget.service,
          ),
        ),
      );
    } catch (e) {
      if (mounted) setState(() => _error = _msg(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _msg(Object e) {
    if (e is ConfigSourceException) return e.message;
    if (e is ConfigCatalogFormatException) return e.message;
    return e.toString();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: const Text('Import config profile'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _urlController,
                    decoration: const InputDecoration(
                      labelText: 'Source URL (catalog or .yaml)',
                      helperText: 'A region\'s catalog, or a direct profile',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _openUrl(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _busy ? null : _openUrl,
                  child: const Text('Load'),
                ),
              ],
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Icon(Icons.error_outline, color: theme.colorScheme.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _error!,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
                ],
              ),
            ),
          const Divider(height: 8),
          Expanded(child: _catalogBody(theme)),
          if (_busy) const LinearProgressIndicator(),
        ],
      ),
    );
  }

  Widget _catalogBody(ThemeData theme) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_entries.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _error == null
                ? 'No profiles published in ${_catalogLabel ?? 'this catalog'} yet.'
                : 'Could not load the catalog.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(_catalogLabel ?? 'Catalog', style: theme.textTheme.titleSmall),
        if (_skipped > 0)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '$_skipped malformed ${_skipped == 1 ? 'entry' : 'entries'} skipped',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        const SizedBox(height: 8),
        for (final e in _entries)
          Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              leading: const Icon(Icons.description_outlined),
              title: Text(e.name),
              subtitle: Text(
                [
                  if (e.region != null) 'Region: ${e.region}',
                  if (e.description != null) e.description!,
                ].join('\n'),
              ),
              isThreeLine: e.description != null && e.region != null,
              trailing: const Icon(Icons.chevron_right),
              onTap: _busy ? null : () => _openProfile(e.url),
            ),
          ),
      ],
    );
  }
}
