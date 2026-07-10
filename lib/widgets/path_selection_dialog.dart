import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import '../l10n/l10n.dart';
import '../models/contact.dart';
import '../l10n/contact_localization.dart';
import '../helpers/snack_bar_builder.dart';

class PathSelectionDialog extends StatefulWidget {
  final List<Contact> availableContacts;
  final String title;
  final String? initialPath;
  final String? currentPathLabel;
  final VoidCallback? onRefresh;
  final int pathHashByteWidth;

  /// A human-readable, name-resolved rendering of a pre-filled suggested route
  /// (e.g. "You → HomeRepeater → Backbone → Target"), shown prominently so the
  /// user can read/verify the inferred route instead of raw hex. (#186)
  final String? suggestedRouteLabel;

  const PathSelectionDialog({
    super.key,
    required this.availableContacts,
    required this.title,
    required this.pathHashByteWidth,
    this.initialPath,
    this.currentPathLabel,
    this.onRefresh,
    this.suggestedRouteLabel,
  });

  @override
  State<PathSelectionDialog> createState() => _PathSelectionDialogState();

  static Future<Uint8List?> show(
    BuildContext context, {
    required List<Contact> availableContacts,
    required int pathHashByteWidth,
    String? title,
    String? initialPath,
    String? currentPathLabel,
    VoidCallback? onRefresh,
    String? suggestedRouteLabel,
  }) {
    return showDialog<Uint8List?>(
      context: context,
      builder: (context) => PathSelectionDialog(
        availableContacts: availableContacts,
        pathHashByteWidth: pathHashByteWidth,
        title: title ?? context.l10n.path_enterCustomPath,
        initialPath: initialPath,
        currentPathLabel: currentPathLabel,
        onRefresh: onRefresh,
        suggestedRouteLabel: suggestedRouteLabel,
      ),
    );
  }

  /// Parses comma-separated hex hop prefixes, each exactly [hashWidth] bytes
  /// wide (clamped >= 1). Wrong-length or malformed entries go to [invalid] and
  /// are skipped — never silently truncated. (#155)
  static List<int> parsePathPrefixes(
    String text,
    int hashWidth,
    List<String> invalid,
  ) {
    final hexLen = (hashWidth < 1 ? 1 : hashWidth) * 2;
    final bytes = <int>[];
    for (final id
        in text.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty)) {
      if (id.length != hexLen) {
        invalid.add(id);
        continue;
      }
      try {
        for (var i = 0; i < hexLen; i += 2) {
          bytes.add(int.parse(id.substring(i, i + 2), radix: 16));
        }
      } catch (_) {
        invalid.add(id);
      }
    }
    return bytes;
  }
}

class _PathSelectionDialogState extends State<PathSelectionDialog> {
  late TextEditingController _controller;
  final List<Contact> _selectedContacts = [];
  List<Contact> _validContacts = [];
  String _search = '';

  // Hop prefix width in bytes (clamped >= 1) and in hex chars, from the device's
  // configured path-hash width. (#155)
  int get _hopWidth =>
      widget.pathHashByteWidth < 1 ? 1 : widget.pathHashByteWidth;
  int get _hexLen => _hopWidth * 2;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialPath ?? '');
    _filterValidContacts();
  }

  @override
  void didUpdateWidget(PathSelectionDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.availableContacts != oldWidget.availableContacts) {
      _filterValidContacts();
    }
  }

  void _filterValidContacts() {
    // Repeaters/rooms only, filtered by the search box, sorted by name so the
    // list is coherent and findable instead of raw contact-store order. (#186)
    final q = _search.trim().toLowerCase();
    _validContacts =
        widget.availableContacts
            .where((c) => c.type == advTypeRepeater || c.type == advTypeRoom)
            .where(
              (c) =>
                  q.isEmpty ||
                  c.name.toLowerCase().contains(q) ||
                  c.publicKeyHex.toLowerCase().startsWith(q),
            )
            .toList()
          ..sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          );
  }

  void _updateTextFromContacts() {
    final hexLen = _hexLen;
    final pathParts = _selectedContacts
        .map((contact) {
          if (contact.publicKeyHex.length >= hexLen) {
            return contact.publicKeyHex.substring(0, hexLen);
          }
          return '';
        })
        .where((s) => s.isNotEmpty)
        .toList();

    _controller.text = pathParts.join(',');
  }

  void _toggleContact(Contact contact) {
    setState(() {
      if (_selectedContacts.contains(contact)) {
        _selectedContacts.remove(contact);
      } else {
        _selectedContacts.add(contact);
      }
      _updateTextFromContacts();
    });
  }

  void _clearSelection() {
    setState(() {
      _selectedContacts.clear();
      _controller.clear();
    });
  }

  Future<void> _validateAndSubmit() async {
    final l10n = context.l10n;
    final path = _controller.text.trim().toUpperCase();
    if (path.isEmpty) {
      if (mounted) Navigator.pop(context);
      return;
    }

    // Parse comma-separated hex prefixes, each exactly one path-hash hop wide.
    final invalidPrefixes = <String>[];
    final pathBytesList = PathSelectionDialog.parsePathPrefixes(
      path,
      widget.pathHashByteWidth,
      invalidPrefixes,
    );

    if (!mounted) return;

    // Show error for invalid prefixes
    if (invalidPrefixes.isNotEmpty) {
      showDismissibleSnackBar(
        context,
        content: Text(l10n.path_invalidHexPrefixes(invalidPrefixes.join(", "))),
        duration: const Duration(seconds: 3),
        backgroundColor: Colors.red,
      );
      return;
    }

    // Check max path length (64 hops)
    if (pathBytesList.length > 64 * _hopWidth) {
      showDismissibleSnackBar(
        context,
        content: Text(l10n.path_tooLong),
        duration: const Duration(seconds: 3),
        backgroundColor: Colors.red,
      );
      return;
    }

    if (pathBytesList.isNotEmpty && mounted) {
      Navigator.pop(context, Uint8List.fromList(pathBytesList));
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.suggestedRouteLabel != null) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.route,
                            size: 16,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSecondaryContainer,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            l10n.path_suggestedRoute,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSecondaryContainer,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        widget.suggestedRouteLabel!,
                        style: TextStyle(
                          fontSize: 13,
                          color: Theme.of(
                            context,
                          ).colorScheme.onSecondaryContainer,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              if (widget.currentPathLabel != null) ...[
                Row(
                  children: [
                    Text(
                      l10n.path_currentPathLabel,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    if (widget.onRefresh != null)
                      TextButton.icon(
                        onPressed: widget.onRefresh,
                        icon: const Icon(Icons.refresh, size: 16),
                        label: Text(l10n.common_reload),
                      ),
                  ],
                ),
                Text(
                  widget.currentPathLabel!,
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
                const SizedBox(height: 16),
              ],
              Text(
                l10n.path_hexPrefixInstructions,
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 8),
              Text(
                l10n.path_hexPrefixExample,
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _controller,
                decoration: InputDecoration(
                  labelText: l10n.path_labelHexPrefixes,
                  hintText: l10n.path_hexPrefixExample,
                  border: const OutlineInputBorder(),
                  helperText: l10n.path_helperMaxHops,
                ),
                textCapitalization: TextCapitalization.characters,
                maxLength: 64 * _hexLen + 63, // 64 hops * (width*2) + 63 commas
              ),
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 8),
              Row(
                children: [
                  Text(
                    l10n.path_selectFromContacts,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  if (_selectedContacts.isNotEmpty)
                    TextButton(
                      onPressed: _clearSelection,
                      child: Text(l10n.common_clear),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                onChanged: (v) => setState(() {
                  _search = v;
                  _filterValidContacts();
                }),
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(Icons.search, size: 18),
                  hintText: l10n.path_searchRepeaters,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              if (_validContacts.isEmpty) ...[
                Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      children: [
                        const Icon(
                          Icons.info_outline,
                          size: 48,
                          color: Colors.grey,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          l10n.path_noRepeatersFound,
                          style: const TextStyle(fontSize: 14),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          l10n.path_customPathsRequire,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.grey,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                ),
              ] else ...[
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 200),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: _validContacts.length,
                    itemBuilder: (context, index) {
                      final contact = _validContacts[index];
                      final isSelected = _selectedContacts.contains(contact);

                      return ListTile(
                        dense: true,
                        leading: CircleAvatar(
                          radius: 16,
                          backgroundColor: isSelected
                              ? Colors.green
                              : (contact.type == 2
                                    ? Colors.blue
                                    : Colors.purple),
                          child: Icon(
                            contact.type == 2
                                ? Icons.router
                                : Icons.meeting_room,
                            size: 16,
                            color: Colors.white,
                          ),
                        ),
                        title: Text(
                          contact.name,
                          style: const TextStyle(fontSize: 14),
                        ),
                        subtitle: Text(
                          '${contact.typeLabel(l10n)} • ${contact.publicKeyHex.length >= _hexLen ? contact.publicKeyHex.substring(0, _hexLen) : contact.publicKeyHex}',
                          style: const TextStyle(fontSize: 10),
                        ),
                        trailing: isSelected
                            ? const Icon(
                                Icons.check_circle,
                                color: Colors.green,
                              )
                            : const Icon(Icons.add_circle_outline),
                        onTap: () => _toggleContact(contact),
                      );
                    },
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.common_cancel),
        ),
        TextButton(
          onPressed: _validateAndSubmit,
          child: Text(l10n.path_setPath),
        ),
      ],
    );
  }
}
