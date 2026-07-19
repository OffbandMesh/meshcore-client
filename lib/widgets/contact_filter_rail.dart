import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../connector/meshcore_protocol.dart';
import '../l10n/l10n.dart';
import '../models/contact.dart';
import '../services/ui_view_state_service.dart';
import '../utils/contact_filter_types.dart';

/// Repeaters never accumulate unread: [MeshCoreConnector] refuses to track it
/// for them, so pairing Unread Only with Repeaters could only ever produce an
/// empty list. Every other type can, so the toggle stays available there.
bool typeSupportsUnread(ContactTypeFilter filter) =>
    filter != ContactTypeFilter.repeaters;

/// Prebuilt contact filters for the nav panel, replacing an empty rail on the
/// Contacts view.
///
/// Unread Only is a toggle rather than a row of its own, because it composes
/// with the type filter: Users plus Unread Only means unread DMs.
class ContactFilterRail extends StatelessWidget {
  const ContactFilterRail({super.key});

  static const _entries = <ContactTypeFilter>[
    ContactTypeFilter.all,
    ContactTypeFilter.favorites,
    ContactTypeFilter.users,
    ContactTypeFilter.repeaters,
    ContactTypeFilter.rooms,
    ContactTypeFilter.sensors,
  ];

  String _label(BuildContext context, ContactTypeFilter filter) {
    final l10n = context.l10n;
    switch (filter) {
      case ContactTypeFilter.all:
        return l10n.listFilter_all;
      case ContactTypeFilter.favorites:
        return l10n.listFilter_favorites;
      case ContactTypeFilter.users:
        return l10n.listFilter_users;
      case ContactTypeFilter.repeaters:
        return l10n.listFilter_repeaters;
      case ContactTypeFilter.rooms:
        return l10n.listFilter_roomServers;
      case ContactTypeFilter.sensors:
        return l10n.listFilter_sensors;
    }
  }

  IconData _icon(ContactTypeFilter filter) {
    switch (filter) {
      case ContactTypeFilter.all:
        return Icons.people_outline;
      case ContactTypeFilter.favorites:
        return Icons.star_outline;
      case ContactTypeFilter.users:
        return Icons.person_outline;
      case ContactTypeFilter.repeaters:
        return Icons.cell_tower;
      case ContactTypeFilter.rooms:
        return Icons.meeting_room_outlined;
      case ContactTypeFilter.sensors:
        return Icons.sensors;
    }
  }

  bool _matches(Contact contact, ContactTypeFilter filter) {
    switch (filter) {
      case ContactTypeFilter.all:
        return true;
      case ContactTypeFilter.favorites:
        return contact.isFavorite;
      case ContactTypeFilter.users:
        return contact.type == advTypeChat;
      case ContactTypeFilter.repeaters:
        return contact.type == advTypeRepeater;
      case ContactTypeFilter.rooms:
        return contact.type == advTypeRoom;
      case ContactTypeFilter.sensors:
        return contact.type == advTypeSensor;
    }
  }

  /// Counts every filter in ONE pass over the contact list.
  ///
  /// The obvious shape (a `where().length` per row) walks the whole list once
  /// per filter, so a 350-contact radio costs ~2100 iterations on every
  /// MeshCoreConnector notification, and those arrive per packet during sync.
  /// One pass keeps it at N, and the per-contact unread lookup is done at most
  /// once rather than once per filter.
  Map<ContactTypeFilter, int> _countsByFilter(
    MeshCoreConnector connector,
    bool unreadOnly,
  ) {
    final counts = {for (final f in _entries) f: 0};
    for (final contact in connector.contacts) {
      // Repeaters are exempt: unread is never tracked for them, so an
      // unread-only view must not drop them from their own row's count.
      final hasUnread =
          !unreadOnly || connector.getUnreadCountForContact(contact) > 0;
      for (final filter in _entries) {
        if (!_matches(contact, filter)) continue;
        if (unreadOnly && typeSupportsUnread(filter) && !hasUnread) continue;
        counts[filter] = counts[filter]! + 1;
      }
    }
    return counts;
  }

  @override
  Widget build(BuildContext context) {
    final connector = context.watch<MeshCoreConnector>();
    final viewState = context.watch<UiViewStateService>();
    final selected = viewState.contactsTypeFilter;
    final unreadOnly = viewState.contactsShowUnreadOnly;
    final counts = _countsByFilter(connector, unreadOnly);

    return ListView(
      padding: EdgeInsets.zero,
      children: [
        for (final filter in _entries)
          _RailTile(
            icon: _icon(filter),
            label: _label(context, filter),
            selected: filter == selected,
            count: counts[filter] ?? 0,
            onTap: () {
              final scaffold = Scaffold.maybeOf(context);
              if (scaffold?.isDrawerOpen ?? false) {
                scaffold!.closeDrawer();
              }
              viewState.setContactsTypeFilter(filter);
            },
          ),
        const Divider(height: 1),
        SwitchListTile(
          dense: true,
          secondary: const Icon(Icons.mark_email_unread_outlined),
          title: Text(context.l10n.listFilter_unreadOnly),
          value: unreadOnly,
          // Disabled on Repeaters, where it could only ever yield nothing.
          onChanged: typeSupportsUnread(selected)
              ? viewState.setContactsShowUnreadOnly
              : null,
        ),
      ],
    );
  }
}

class _RailTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final int count;
  final VoidCallback onTap;

  const _RailTile({
    required this.icon,
    required this.label,
    required this.selected,
    required this.count,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      dense: true,
      selected: selected,
      selectedTileColor: theme.colorScheme.secondaryContainer,
      leading: Icon(icon, size: 20),
      title: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
      // Deliberately not UnreadBadge: this is a total for the filter, not an
      // unread count, and the badge styling would imply unread.
      trailing: Text(
        '$count',
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      onTap: onTap,
    );
  }
}
