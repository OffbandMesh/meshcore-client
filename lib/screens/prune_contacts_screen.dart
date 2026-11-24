import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../helpers/snack_bar_builder.dart';
import '../helpers/stale_contacts.dart';
import '../l10n/l10n.dart';
import '../models/contact.dart';
import '../widgets/contact_add_feedback.dart';

/// Lists contacts not heard in a chosen number of days, all ticked, and
/// removes the ticked ones from the radio one at a time. Favorites are never
/// listed and DMs are kept. Pops with the number removed. (#1182)
class PruneContactsScreen extends StatefulWidget {
  const PruneContactsScreen({super.key});

  @override
  State<PruneContactsScreen> createState() => _PruneContactsScreenState();
}

class _PruneContactsScreenState extends State<PruneContactsScreen> {
  int _days = defaultPruneDays;
  final Set<String> _kept = {};
  bool _running = false;

  Future<void> _prune(
    MeshCoreConnector connector,
    List<Contact> contacts,
  ) async {
    setState(() => _running = true);
    final result = await connector.pruneContacts(contacts);
    if (!mounted) return;
    setState(() => _running = false);
    final l10n = context.l10n;
    final failed = result.failed;
    if (failed == null) {
      showDismissibleSnackBar(
        context,
        content: Text(l10n.contacts_pruneDone(result.removed)),
      );
    } else {
      showDismissibleSnackBar(
        context,
        content: Text(
          '${l10n.contacts_pruneStopped(result.removed, contacts.length)} '
          '${contactRemoveFailureText(context, result.failure!, failed.name)}',
        ),
        persist: true,
      );
    }
    Navigator.pop(context, result.removed);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final connector = context.watch<MeshCoreConnector>();
    final stale = connector.staleContacts(Duration(days: _days));
    final selected = stale
        .where((c) => !_kept.contains(c.publicKeyHex))
        .toList();
    final now = DateTime.now();

    return Scaffold(
      appBar: AppBar(title: Text(l10n.contacts_pruneTitle), centerTitle: true),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: SegmentedButton<int>(
              segments: [
                for (final d in pruneDayChoices)
                  ButtonSegment(
                    value: d,
                    label: Text(l10n.contacts_pruneDays(d)),
                  ),
              ],
              selected: {_days},
              onSelectionChanged: _running
                  ? null
                  : (s) => setState(() => _days = s.first),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              l10n.contacts_pruneNote,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          Expanded(
            child: stale.isEmpty
                ? Center(child: Text(l10n.contacts_pruneEmpty))
                : ListView.builder(
                    itemCount: stale.length,
                    itemBuilder: (context, i) {
                      final c = stale[i];
                      return CheckboxListTile(
                        value: !_kept.contains(c.publicKeyHex),
                        onChanged: _running
                            ? null
                            : (v) => setState(() {
                                v == true
                                    ? _kept.remove(c.publicKeyHex)
                                    : _kept.add(c.publicKeyHex);
                              }),
                        title: Text(c.name),
                        subtitle: Text(
                          l10n.contacts_lastHeardDays(
                            now.difference(lastHeard(c)).inDays,
                          ),
                        ),
                      );
                    },
                  ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _running || selected.isEmpty
                      ? null
                      : () => _prune(connector, selected),
                  child: _running
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(l10n.contacts_pruneRemove(selected.length)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
