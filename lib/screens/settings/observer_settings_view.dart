import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/observer_config.dart';
import '../../services/observer_config_service.dart';

/// Observer settings pane: WiFi / MQTT (region) / display flat settings with
/// staged-save, plus a read-only view of the MQTT broker pool.
///
/// Staged-save model: every control edits LOCAL state; nothing reaches the
/// device until "Save", which sends only the changed keys (the firmware has no
/// transaction, so each is an individual SET awaiting its ACK). Device NVS is
/// the source of truth — Refresh re-reads it.
///
/// TODO(l10n): strings are English-only pending ARB keys.
/// TODO(#64 / firmware F-task): broker enable/disable/clear + the broker editor
/// are blocked on the firmware wire path (no `enabled` SET; VIEW allowlist is
/// read-only), so the broker pool is read-only here for now.
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  @override
  void dispose() {
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
    await setIfChanged(
      c == null || _statusInterval.text != '${c.mqtt.statusInterval}',
      'mqtt.status_interval',
      _statusInterval.text,
    );
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
    await svc.refresh();
    _seedFromConfig(svc.config);
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
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
        _sectionTitle('MQTT brokers'),
        ..._brokerTiles(svc.config?.brokers ?? const []),
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

  List<Widget> _brokerTiles(List<BrokerConfig> brokers) {
    final populated = brokers.where((b) => b.isPopulated).toList();
    if (populated.isEmpty) {
      return [
        const ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('No brokers configured'),
        ),
      ];
    }
    return [
      const Padding(
        padding: EdgeInsets.only(bottom: 4),
        child: Text(
          'Read-only — enable/disable/clear pending firmware support.',
          style: TextStyle(fontStyle: FontStyle.italic),
        ),
      ),
      for (final b in populated)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            b.enabled ? Icons.cloud_done : Icons.cloud_off,
            color: b.enabled ? Colors.green : null,
          ),
          title: Text('[${b.slot}] ${b.url}:${b.port}'),
          subtitle: Text(
            '${b.transport.wire} · ${b.authType.wire}'
            '${b.passwordSet ? ' · pwd set' : ''}',
          ),
        ),
    ];
  }
}
