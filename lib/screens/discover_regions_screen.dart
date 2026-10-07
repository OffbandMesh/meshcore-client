import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../l10n/app_localizations.dart';
import '../l10n/l10n.dart';
import '../models/contact.dart';
import '../services/region_discovery_service.dart';

/// Discover the flood regions a repeater advertises (Feature #812, Epic #814).
///
/// Launched from the repeater hub for a specific repeater, so the source node
/// is [repeater]; the reply carries only region names and the repeater clock
/// (there is no per-region SNR on the wire). Each outcome renders distinctly:
/// loading, the region list, no-regions, timeout, or error.
class DiscoverRegionsScreen extends StatefulWidget {
  const DiscoverRegionsScreen({
    super.key,
    required this.repeater,
    this.service,
  });

  final Contact repeater;

  /// Test seam: inject a service with a fake discoverer. In production the
  /// service is built from the connector.
  final RegionDiscoveryService? service;

  @override
  State<DiscoverRegionsScreen> createState() => _DiscoverRegionsScreenState();
}

class _DiscoverRegionsScreenState extends State<DiscoverRegionsScreen> {
  late final RegionDiscoveryService _service;
  late final bool _ownsService;

  @override
  void initState() {
    super.initState();
    final injected = widget.service;
    _ownsService = injected == null;
    if (injected != null) {
      _service = injected;
    } else {
      final connector = context.read<MeshCoreConnector>();
      _service = RegionDiscoveryService(
        (pub, timeout) =>
            connector.discoverRegions(repeaterPubKey: pub, timeout: timeout),
      );
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _start();
    });
  }

  void _start() => _service.discover(widget.repeater.publicKey);

  @override
  void dispose() {
    if (_ownsService) _service.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.discoverRegions_title),
        centerTitle: true,
      ),
      body: ListenableBuilder(
        listenable: _service,
        builder: (context, _) => _body(l10n),
      ),
    );
  }

  Widget _body(AppLocalizations l10n) {
    final name = widget.repeater.name;
    switch (_service.status) {
      case RegionDiscoveryStatus.idle:
      case RegionDiscoveryStatus.loading:
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(l10n.discoverRegions_loading(name)),
            ],
          ),
        );
      case RegionDiscoveryStatus.success:
        return _regionList(l10n);
      case RegionDiscoveryStatus.empty:
        return _message(
          stateKey: 'discoverRegionsEmpty',
          icon: Icons.location_off,
          text: l10n.discoverRegions_empty(name),
          l10n: l10n,
        );
      case RegionDiscoveryStatus.timeout:
        return _message(
          stateKey: 'discoverRegionsTimeout',
          icon: Icons.timer_off,
          text: l10n.discoverRegions_timeout(name),
          l10n: l10n,
        );
      case RegionDiscoveryStatus.error:
        return _message(
          stateKey: 'discoverRegionsError',
          icon: Icons.error_outline,
          text: _service.errorMessage ?? l10n.discoverRegions_error,
          l10n: l10n,
        );
    }
  }

  Widget _regionList(AppLocalizations l10n) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              const Icon(Icons.cell_tower),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.discoverRegions_source(widget.repeater.name),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.builder(
            itemCount: _service.regions.length,
            itemBuilder: (context, i) {
              final region = _service.regions[i];
              return ListTile(
                leading: Icon(region.isWildcard ? Icons.public : Icons.tag),
                title: Text(region.name),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _message({
    required String stateKey,
    required IconData icon,
    required String text,
    required AppLocalizations l10n,
  }) {
    return Center(
      key: Key(stateKey),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(text, textAlign: TextAlign.center),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: ElevatedButton(
              key: const Key('discoverRegionsRetry'),
              onPressed: _start,
              child: Text(l10n.discoverRegions_retry),
            ),
          ),
        ],
      ),
    );
  }
}
