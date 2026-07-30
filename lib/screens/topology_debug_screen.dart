import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../connector/meshcore_protocol.dart';
import '../helpers/snack_bar_builder.dart';
import '../models/contact.dart';
import '../services/mesh_topology_service.dart';
import '../widgets/adaptive_app_bar_title.dart';

/// Read-only diagnostic view of the passively-learned mesh topology (#196 /
/// epic #186). It answers one question on real hardware: is
/// [MeshTopologyService] actually ingesting? Node/edge counts climb as routed
/// packets arrive; stuck at zero while traffic flows means the RX ingestion
/// wiring is dead. Strings are hardcoded EN on purpose, this is a dev-facing
/// diagnostic, deliberately not part of the localized UX surface.
class TopologyDebugScreen extends StatelessWidget {
  const TopologyDebugScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final contacts = context.read<MeshCoreConnector>().contacts;
    return Consumer<MeshTopologyService>(
      builder: (context, topo, _) {
        final now = topo.clockSeconds;
        final self = topo.self;
        final nodes = topo.nodes.toList()
          ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
        final edges = topo.edges.toList()
          ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
        final hasData = nodes.isNotEmpty || edges.isNotEmpty;

        return Scaffold(
          appBar: AppBar(
            title: const AdaptiveAppBarTitle('Mesh topology'),
            centerTitle: true,
            actions: [
              IconButton(
                tooltip: 'Copy dump',
                icon: const Icon(Icons.copy),
                onPressed: !hasData
                    ? null
                    : () async {
                        await Clipboard.setData(
                          ClipboardData(text: _dump(topo, contacts, now)),
                        );
                        if (!context.mounted) return;
                        showDismissibleSnackBar(
                          context,
                          content: const Text('Topology copied'),
                        );
                      },
              ),
            ],
          ),
          body: SafeArea(
            top: false,
            child: ListView(
              children: [
                _summary(context, topo, self, contacts),
                const Divider(height: 1),
                if (nodes.isEmpty)
                  _empty(context)
                else ...[
                  _sectionHeader(context, 'Nodes (${nodes.length})'),
                  for (final n in nodes)
                    _nodeTile(context, n, self, contacts, now),
                  const Divider(height: 1),
                  _sectionHeader(context, 'Edges (${edges.length})'),
                  for (final e in edges) _edgeTile(context, e, contacts, now),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _summary(
    BuildContext context,
    MeshTopologyService topo,
    Uint8List? self,
    List<Contact> contacts,
  ) {
    final selfLabel = self == null
        ? 'not set yet, waiting for first packet'
        : (_nameOf(self, contacts) == null
              ? _hex(self)
              : '${_nameOf(self, contacts)} (${_hex(self)})');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _stat(context, '${topo.nodeCount}', 'nodes'),
              _stat(context, '${topo.edgeCount}', 'edges'),
              _stat(context, '${topo.freshnessSeconds ~/ 86400}d', 'freshness'),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'You: $selfLabel',
            style: TextStyle(
              fontSize: 12,
              fontFamily: 'monospace',
              color: Colors.grey[700],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Passive map of routed-packet paths. Counts climb as traffic '
            'arrives; stuck at 0 while messages flow means ingestion is dead.',
            style: TextStyle(fontSize: 11, color: Colors.grey[600]),
          ),
        ],
      ),
    );
  }

  Widget _stat(BuildContext context, String value, String label) {
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          ),
          Text(label, style: TextStyle(fontSize: 11, color: Colors.grey[600])),
        ],
      ),
    );
  }

  Widget _sectionHeader(BuildContext context, String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        text,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _nodeTile(
    BuildContext context,
    TopoNode n,
    Uint8List? self,
    List<Contact> contacts,
    int now,
  ) {
    final hex = _hex(n.prefix);
    final isSelf = self != null && hex == _hex(self);
    final name = isSelf ? 'You' : _nameOf(n.prefix, contacts);
    final snr = n.neighbourSnr;
    final meta = <String>[
      'seen ×${n.seenCount}',
      _age(n.lastSeen, now),
      if (snr != null) 'SNR ${snr.toStringAsFixed(1)}',
    ].join(' · ');
    return ListTile(
      dense: true,
      leading: Icon(
        isSelf
            ? Icons.my_location
            : (snr != null ? Icons.cell_tower : Icons.hub_outlined),
        size: 18,
        color: isSelf
            ? Colors.blue
            : (snr != null ? Colors.green : Colors.grey),
      ),
      title: Text(
        name ?? hex,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
      ),
      subtitle: Text(
        name != null ? '$hex · $meta' : meta,
        style: TextStyle(
          fontSize: 11,
          fontFamily: 'monospace',
          color: Colors.grey[600],
        ),
      ),
    );
  }

  Widget _edgeTile(
    BuildContext context,
    TopoEdge e,
    List<Contact> contacts,
    int now,
  ) {
    final a = _nameOf(e.a, contacts) ?? _hex(e.a);
    final b = _nameOf(e.b, contacts) ?? _hex(e.b);
    final failed = e.lastFailed != null;
    final meta = <String>[
      '×${e.count}',
      _age(e.lastSeen, now),
      if (failed) 'failed ${_age(e.lastFailed!, now)}',
    ].join(' · ');
    return ListTile(
      dense: true,
      leading: Icon(
        failed ? Icons.link_off : Icons.link,
        size: 18,
        color: failed ? Colors.orange : Colors.grey,
      ),
      title: Text('$a ~ $b', style: const TextStyle(fontSize: 13)),
      subtitle: Text(
        meta,
        style: TextStyle(fontSize: 11, color: Colors.grey[600]),
      ),
    );
  }

  Widget _empty(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
      child: Column(
        children: [
          Icon(Icons.hub_outlined, size: 56, color: Colors.grey[400]),
          const SizedBox(height: 12),
          Text(
            'No topology learned yet',
            style: TextStyle(fontSize: 15, color: Colors.grey[600]),
          ),
          const SizedBox(height: 6),
          Text(
            'Listening. This fills as routed packets arrive from the mesh. '
            'Leave it connected a few minutes.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: Colors.grey[500]),
          ),
        ],
      ),
    );
  }

  // ── pure helpers (also used by the clipboard dump) ──────────────────────

  static String? _nameOf(List<int> prefix, List<Contact> contacts) {
    final matches = contacts
        .where(
          (c) =>
              c.publicKey.length >= prefix.length &&
              _startsWith(c.publicKey, prefix) &&
              (c.type == advTypeRepeater || c.type == advTypeRoom),
        )
        .toList();
    if (matches.isEmpty) return null;
    if (matches.length == 1) return matches.first.name;
    return matches.map((c) => c.name).join(' | ');
  }

  static bool _startsWith(List<int> pubkey, List<int> prefix) {
    for (var i = 0; i < prefix.length; i++) {
      if (pubkey[i] != prefix[i]) return false;
    }
    return true;
  }

  static String _hex(List<int> b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0').toUpperCase()).join();

  static String _age(int lastSeen, int now) {
    final s = now - lastSeen;
    if (s < 0) return 'now';
    if (s < 60) return '${s}s ago';
    if (s < 3600) return '${s ~/ 60}m ago';
    if (s < 86400) return '${s ~/ 3600}h ago';
    return '${s ~/ 86400}d ago';
  }

  static String _dump(
    MeshTopologyService topo,
    List<Contact> contacts,
    int now,
  ) {
    final self = topo.self;
    final buf = StringBuffer()
      ..writeln(
        'Mesh topology: ${topo.nodeCount} nodes, ${topo.edgeCount} edges',
      )
      ..writeln('self: ${self == null ? "(unset)" : _hex(self)}')
      ..writeln('freshness: ${topo.freshnessSeconds ~/ 86400}d')
      ..writeln('')
      ..writeln('NODES:');
    for (final n
        in topo.nodes.toList()
          ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen))) {
      final nm = _nameOf(n.prefix, contacts);
      final snr = n.neighbourSnr;
      buf.writeln(
        '  ${_hex(n.prefix)}${nm != null ? " ($nm)" : ""} '
        'seen×${n.seenCount} ${_age(n.lastSeen, now)}'
        '${snr != null ? " SNR ${snr.toStringAsFixed(1)}" : ""}',
      );
    }
    buf.writeln('EDGES:');
    for (final e
        in topo.edges.toList()
          ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen))) {
      buf.writeln(
        '  ${_hex(e.a)} ~ ${_hex(e.b)} ×${e.count} '
        '${_age(e.lastSeen, now)}${e.lastFailed != null ? " FAILED" : ""}',
      );
    }
    return buf.toString();
  }
}
