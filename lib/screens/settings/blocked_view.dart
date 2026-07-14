import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../connector/meshcore_connector.dart';
import '../../l10n/l10n.dart';
import '../../services/block_service.dart';

/// Embeddable view (no Scaffold) for the Blocked settings pane.
///
/// Lists blocked public keys (with the contact name when resolvable) and
/// name-only channel blocks, each with an Unblock action. App-local; the
/// firmware-offload indicator is added by Epic B.
class BlockedView extends StatelessWidget {
  const BlockedView({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer2<BlockService, MeshCoreConnector>(
      builder: (context, block, connector, child) {
        final keys = block.blockedKeys.toList()..sort();
        final names = block.blockedNames.keys.toList()..sort();
        final indicator = _offloadIndicator(context, connector);
        if (keys.isEmpty && names.isEmpty) {
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              ?indicator,
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 48),
                child: Center(child: Text(context.l10n.block_none)),
              ),
            ],
          );
        }
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            ?indicator,
            if (keys.isNotEmpty) ...[
              _sectionHeader(context.l10n.block_keysSection),
              ...keys.map((k) => _keyTile(context, block, connector, k)),
              const SizedBox(height: 16),
            ],
            if (names.isNotEmpty) ...[
              _sectionHeader(context.l10n.block_namesSection),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Text(
                  context.l10n.block_namesHint,
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
              ),
              ...names.map((n) => _nameTile(context, block, n)),
            ],
          ],
        );
      },
    );
  }

  /// Firmware-offload status row (only when the radio supports block offload):
  /// "active" normally, or a "store full" warning when the node hit its cap.
  Widget? _offloadIndicator(BuildContext context, MeshCoreConnector connector) {
    if (!connector.supportsOffbandBlock) return null;
    final full = connector.blockOffloadStoreFull;
    return Card(
      child: ListTile(
        dense: true,
        leading: Icon(
          full ? Icons.warning_amber : Icons.sync,
          color: full ? Colors.amber.shade800 : Colors.green,
        ),
        title: Text(
          full
              ? context.l10n.block_offloadStoreFull
              : context.l10n.block_offloadActive,
        ),
      ),
    );
  }

  Widget _sectionHeader(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
    child: Text(
      text,
      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
    ),
  );

  String? _nameForKey(MeshCoreConnector connector, String keyHex) {
    for (final c in connector.contacts) {
      if (c.publicKeyHex == keyHex) return c.name;
    }
    for (final c in connector.discoveredContacts) {
      if (c.publicKeyHex == keyHex) return c.name;
    }
    return null;
  }

  Widget _keyTile(
    BuildContext context,
    BlockService block,
    MeshCoreConnector connector,
    String keyHex,
  ) {
    final name = _nameForKey(connector, keyHex);
    final shortKey =
        '${keyHex.substring(0, 8)}…${keyHex.substring(keyHex.length - 8)}';
    return ListTile(
      leading: Icon(Icons.block, color: Colors.red.shade700),
      title: Text(name ?? shortKey),
      subtitle: name != null ? Text(shortKey) : null,
      trailing: TextButton(
        onPressed: () => block.unblock(keyHex),
        child: Text(context.l10n.block_unblock),
      ),
    );
  }

  Widget _nameTile(BuildContext context, BlockService block, String name) {
    return ListTile(
      leading: Icon(Icons.block, color: Colors.red.shade700),
      title: Text(name),
      trailing: TextButton(
        onPressed: () => block.unblockName(name),
        child: Text(context.l10n.block_unblock),
      ),
    );
  }
}
