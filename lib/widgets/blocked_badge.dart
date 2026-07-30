import 'package:flutter/material.dart';

/// Small red "blocked" indicator (circle-with-slash) shown next to a blocked
/// entry's name in the contacts/discovery lists. Blocked entries stay visible
/// (not hidden), see `docs/architecture/block-contract-as-built.md`.
class BlockedBadge extends StatelessWidget {
  final double size;
  const BlockedBadge({super.key, this.size = 16});

  @override
  Widget build(BuildContext context) {
    return Icon(Icons.block, size: size, color: Colors.red.shade700);
  }
}
