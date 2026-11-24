import '../models/contact.dart';

/// Prune choices offered to the user, in days; [defaultPruneDays] is
/// preselected. Owner decision 2026-11-24 (#1182).
const List<int> pruneDayChoices = [15, 30, 90];
const int defaultPruneDays = 30;

/// The last time anything was heard from [contact]: its newest advert, the
/// newest message, or the radio's own last change to the record.
DateTime lastHeard(Contact contact) {
  var latest = contact.lastSeen;
  for (final t in [contact.lastMessageAt, contact.lastModified]) {
    if (t != null && t.isAfter(latest)) latest = t;
  }
  return latest;
}

/// Non-favorite contacts last heard before [now] minus [olderThan], oldest
/// first. Favorites are never pruned, and neither is any key in [exclude].
List<Contact> staleContacts(
  Iterable<Contact> contacts, {
  required DateTime now,
  required Duration olderThan,
  Set<String> exclude = const {},
}) {
  final cutoff = now.subtract(olderThan);
  final stale = contacts
      .where(
        (c) =>
            !c.isFavorite &&
            !exclude.contains(c.publicKeyHex) &&
            lastHeard(c).isBefore(cutoff),
      )
      .toList();
  stale.sort((a, b) => lastHeard(a).compareTo(lastHeard(b)));
  return stale;
}

/// The contact to suggest removing when the radio is full: the least
/// recently heard non-favorite, or null when every contact is a favorite.
Contact? leastRecentlyHeard(
  Iterable<Contact> contacts, {
  Set<String> exclude = const {},
}) {
  Contact? oldest;
  for (final c in contacts) {
    if (c.isFavorite || exclude.contains(c.publicKeyHex)) continue;
    if (oldest == null || lastHeard(c).isBefore(lastHeard(oldest))) {
      oldest = c;
    }
  }
  return oldest;
}
