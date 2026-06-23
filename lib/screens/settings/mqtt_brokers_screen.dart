import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../connector/observer_config_client.dart';
import '../../models/observer_config.dart';
import '../../services/observer_config_service.dart';
import 'broker_editor_screen.dart';

/// The MQTT broker pool as its own screen (#80), reached from the Observer
/// settings pane. Tap a broker to edit it; long-press for Enable / Disable /
/// Edit / Clear; the `+` FAB adds the next empty slot — matching the FAB-add
/// pattern of channels_screen. Single-slot re-GET keeps it off the 84-frame
/// pool dump after each action.
class MqttBrokersScreen extends StatefulWidget {
  const MqttBrokersScreen({super.key});

  @override
  State<MqttBrokersScreen> createState() => _MqttBrokersScreenState();
}

class _MqttBrokersScreenState extends State<MqttBrokersScreen> {
  List<BrokerConfig> _brokers = const [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _brokers =
        context.read<ObserverConfigService>().config?.brokers ?? const [];
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  Future<void> _reload() async {
    final svc = context.read<ObserverConfigService>();
    setState(() => _busy = true);
    final list = await svc.getBrokers();
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (list != null) _brokers = list;
    });
  }

  int? get _nextEmptySlot {
    final used = _brokers.map((b) => b.slot).toSet();
    for (var i = 0; i < ObserverConfigClient.brokerSlotCount; i++) {
      if (!used.contains(i)) return i;
    }
    return null;
  }

  Future<void> _openEditor(BrokerConfig b) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => BrokerEditorScreen(broker: b)),
    );
    if (saved == true && mounted) await _reload();
  }

  Future<void> _quickToggle(BrokerConfig b, bool enable) async {
    final svc = context.read<ObserverConfigService>();
    await svc.setBrokerField(b.slot, 'enabled', enable ? '1' : '0');
    if (mounted) await _reload();
  }

  Future<void> _clear(BrokerConfig b) async {
    final svc = context.read<ObserverConfigService>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Clear broker ${b.slot}?'),
        content: const Text(
          'This wipes the slot on the device. You can set it up again later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await svc.clearBroker(b.slot);
    if (mounted) await _reload();
  }

  Future<void> _menu(BrokerConfig b) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (b.enabled)
              ListTile(
                leading: const Icon(Icons.cloud_off),
                title: const Text('Disable'),
                onTap: () => Navigator.pop(c, 'disable'),
              )
            else
              ListTile(
                leading: const Icon(Icons.cloud_done),
                title: const Text('Enable'),
                onTap: () => Navigator.pop(c, 'enable'),
              ),
            ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('Edit'),
              onTap: () => Navigator.pop(c, 'edit'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Clear'),
              onTap: () => Navigator.pop(c, 'clear'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'enable':
        await _quickToggle(b, true);
      case 'disable':
        await _quickToggle(b, false);
      case 'edit':
        await _openEditor(b);
      case 'clear':
        await _clear(b);
    }
  }

  @override
  Widget build(BuildContext context) {
    final slot = _nextEmptySlot;
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: const Text('MQTT brokers'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _busy ? null : _reload,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: slot == null ? 'All broker slots are full' : 'Add broker',
        onPressed: slot == null
            ? null
            : () => _openEditor(BrokerConfig.empty(slot)),
        child: const Icon(Icons.add),
      ),
      body: _brokers.isEmpty
          ? const Center(
              child: Text('No brokers configured — tap + to add one'),
            )
          : ListView(
              children: [
                for (final b in _brokers)
                  ListTile(
                    leading: Icon(
                      b.enabled ? Icons.cloud_done : Icons.cloud_off,
                      color: b.enabled ? Colors.green : null,
                    ),
                    title: Text('[${b.slot}] ${b.url}'),
                    subtitle: Text(
                      '${b.port} · ${b.transport.wire}'
                      '${b.enabled ? '' : ' · disabled'}',
                    ),
                    onTap: () => _openEditor(b),
                    onLongPress: () => _menu(b),
                  ),
              ],
            ),
    );
  }
}
