import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../connector/meshcore_connector.dart';
import '../../models/observer_config.dart';
import '../../services/observer_config_service.dart';
import 'config_profile_import_screen.dart';
import 'mqtt_brokers_screen.dart';

/// Observer settings pane: WiFi / MQTT (region) / display flat settings with
/// staged-save, plus a row into the MQTT broker editor (#80).
///
/// Staged-save model: every control edits LOCAL state; nothing reaches the
/// device until "Save", which sends only the changed keys (the firmware has no
/// transaction, so each is an individual SET awaiting its ACK). Device NVS is
/// the source of truth — Refresh re-reads it.
///
/// TODO(l10n): strings are English-only pending ARB keys.
/// The broker pool opens as its own screen (MqttBrokersScreen, #80) — tap to
/// edit, long-press for Enable/Disable/Edit/Clear, + FAB to add.
class ObserverSettingsView extends StatefulWidget {
  const ObserverSettingsView({super.key});

  @override
  State<ObserverSettingsView> createState() => _ObserverSettingsViewState();
}

class _ObserverSettingsViewState extends State<ObserverSettingsView> {
  final _ssid = TextEditingController();
  final _pwd = TextEditingController();
  final _iata = TextEditingController();
  final _statusInterval = TextEditingController();
  bool _wifiEnabled = true;
  bool _displayAlwaysOn = false;
  int _rotation = 0;

  bool _loading = false;
  bool _saving = false;
  bool _seeded = false;
  bool _waitingForSync = false;
  MeshCoreConnector? _syncWaitConn;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshWhenIdle());
  }

  /// Defer the initial read until the device's channel/contact sync settles —
  /// observer config traffic must not compete with (and slow) that sync (#81).
  void _refreshWhenIdle() {
    final conn = context.read<MeshCoreConnector>();
    if (!_syncing(conn)) {
      _refresh();
      return;
    }
    setState(() => _waitingForSync = true);
    _syncWaitConn = conn;
    conn.addListener(_onSyncProgress);
  }

  void _onSyncProgress() {
    final conn = _syncWaitConn;
    if (conn == null || _syncing(conn)) return;
    conn.removeListener(_onSyncProgress);
    _syncWaitConn = null;
    if (!mounted) return;
    setState(() => _waitingForSync = false);
    _refresh();
  }

  bool _syncing(MeshCoreConnector c) =>
      c.isLoadingContacts ||
      c.isSyncingChannels ||
      c.isShowingQueuedMessageSyncProgress;

  @override
  void dispose() {
    _syncWaitConn?.removeListener(_onSyncProgress);
    _ssid.dispose();
    _pwd.dispose();
    _iata.dispose();
    _statusInterval.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final svc = context.read<ObserverConfigService>();
    setState(() => _loading = true);
    await svc.refresh();
    _seedFromConfig(svc.config);
    if (mounted) setState(() => _loading = false);
  }

  void _seedFromConfig(ObserverConfig? c) {
    if (c == null) return;
    _ssid.text = c.wifi.ssid;
    _wifiEnabled = c.wifi.enabled;
    _iata.text = c.mqtt.iata;
    _statusInterval.text = '${c.mqtt.statusInterval}';
    _displayAlwaysOn = c.display.alwaysOn;
    // Device may report any int; the SegmentedButton only offers {0, 180}, so
    // normalize to a valid selection rather than seed a dangling value.
    _rotation = c.display.rotation == 180 ? 180 : 0;
    _seeded = true;
  }

  Future<void> _save() async {
    final svc = context.read<ObserverConfigService>();
    final c = svc.config;
    setState(() => _saving = true);
    var ok = true;
    var invalidInterval = false;

    Future<void> setIfChanged(bool changed, String key, String value) async {
      if (changed) ok = await svc.setFlat(key, value) && ok;
    }

    await setIfChanged(
      c == null || _ssid.text != c.wifi.ssid,
      'wifi.ssid',
      _ssid.text,
    );
    if (_pwd.text.isNotEmpty) {
      ok = await svc.setFlat('wifi.pwd', _pwd.text) && ok;
    }
    await setIfChanged(
      c == null || _wifiEnabled != c.wifi.enabled,
      'wifi.enabled',
      _wifiEnabled ? '1' : '0',
    );
    await setIfChanged(
      c == null || _iata.text != c.mqtt.iata,
      'mqtt.iata',
      _iata.text,
    );
    // Validate before sending: the firmware range is 10-3600. Don't put a
    // predictably invalid value on the wire (#78 MINOR-B).
    if (c == null || _statusInterval.text != '${c.mqtt.statusInterval}') {
      final n = int.tryParse(_statusInterval.text);
      if (n != null && n >= 10 && n <= 3600) {
        ok = await svc.setFlat('mqtt.status_interval', '$n') && ok;
      } else {
        invalidInterval = true;
        ok = false;
      }
    }
    await setIfChanged(
      c == null || _displayAlwaysOn != c.display.alwaysOn,
      'display.always_on',
      _displayAlwaysOn ? '1' : '0',
    );
    await setIfChanged(
      c == null || _rotation != c.display.rotation,
      'display.rotation',
      '$_rotation',
    );

    _pwd.clear();
    // Flat save: don't re-pull the 84-frame broker pool, just the flats (#81).
    await svc.refresh(includeBrokers: false);
    _seedFromConfig(svc.config);
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          invalidInterval
              ? 'Status interval must be 10–3600 seconds'
              : ok
              ? 'Observer settings saved'
              : (svc.lastError ??
                    'Some changes failed — re-read from the device'),
        ),
        backgroundColor: ok ? null : Theme.of(context).colorScheme.error,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<ObserverConfigService>();
    if (_waitingForSync && !_seeded) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Waiting for the device sync to finish before reading Observer settings…',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (!_seeded && _loading) {
      return const Center(child: CircularProgressIndicator());
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (svc.stale)
          _banner(
            Icons.warning_amber,
            'Showing the last read — the device did not answer the latest refresh.',
          ),
        if (svc.lastError != null) _banner(Icons.error_outline, svc.lastError!),
        _actionRow(),
        const SizedBox(height: 8),
        _sectionTitle('WiFi'),
        TextField(
          key: const Key('observer_ssid'),
          controller: _ssid,
          decoration: const InputDecoration(
            labelText: 'SSID',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('observer_pwd'),
          controller: _pwd,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'Password (leave blank to keep)',
            border: OutlineInputBorder(),
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('WiFi enabled'),
          subtitle: Text(_wifiStatusLine(svc.config?.wifi)),
          value: _wifiEnabled,
          onChanged: (v) => setState(() => _wifiEnabled = v),
        ),
        const Divider(height: 32),
        _sectionTitle('MQTT / Region'),
        TextField(
          controller: _iata,
          decoration: const InputDecoration(
            labelText: 'Region tag (mqtt.iata)',
            helperText: 'MQTT topic region, e.g. HAO',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('observer_interval'),
          controller: _statusInterval,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(
            labelText: 'Status interval (sec, 10-3600)',
            border: OutlineInputBorder(),
          ),
        ),
        const Divider(height: 32),
        _sectionTitle('Display'),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Always on'),
          subtitle: const Text('Keep the screen lit (USB/mains nodes)'),
          value: _displayAlwaysOn,
          onChanged: (v) => setState(() => _displayAlwaysOn = v),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              const Text('Rotation'),
              const SizedBox(width: 16),
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 0, label: Text('0°')),
                  ButtonSegment(value: 180, label: Text('180°')),
                ],
                selected: {_rotation},
                onSelectionChanged: (s) => setState(() => _rotation = s.first),
              ),
            ],
          ),
        ),
        const Divider(height: 32),
        if (svc.brokersUnavailable)
          _banner(
            Icons.cloud_off,
            'Broker pool unavailable — the device did not finish sending it.',
          )
        else
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.dns_outlined),
            title: const Text('MQTT brokers'),
            subtitle: Text(_brokerSummary(svc.config?.brokers ?? const [])),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const MqttBrokersScreen()),
            ),
          ),
        const Divider(height: 32),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.download_outlined),
          title: const Text('Import config profile'),
          subtitle: const Text(
            'Apply region / WiFi / brokers from a catalog or URL',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => ConfigProfileImportScreen(service: svc),
            ),
          ),
        ),
      ],
    );
  }

  Widget _actionRow() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        TextButton.icon(
          onPressed: (_loading || _saving) ? null : _refresh,
          icon: const Icon(Icons.refresh),
          label: const Text('Refresh'),
        ),
        const SizedBox(width: 8),
        FilledButton.icon(
          onPressed: (_loading || _saving) ? null : _save,
          icon: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.save),
          label: const Text('Save'),
        ),
      ],
    );
  }

  Widget _sectionTitle(String t) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(t, style: Theme.of(context).textTheme.titleMedium),
  );

  Widget _banner(IconData icon, String msg) {
    final color = Theme.of(context).colorScheme.error;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(msg, style: TextStyle(color: color)),
          ),
        ],
      ),
    );
  }

  String _wifiStatusLine(WifiConfig? w) {
    if (w == null) return '';
    final ip = w.ip != null ? ' · ${w.ip}' : '';
    return 'Status: ${w.status.name}$ip';
  }

  String _brokerSummary(List<BrokerConfig> brokers) {
    final populated = brokers.where((b) => b.isPopulated).toList();
    if (populated.isEmpty) return 'None configured — tap to add';
    final enabled = populated.where((b) => b.enabled).length;
    return '${populated.length} configured · $enabled enabled';
  }
}
