import 'drift/blob_store.dart';
import 'scoping_inventory.dart';

/// Deletes everything this app stores for one radio, after that radio was
/// factory reset (#1054).
///
/// Driven by [storageSurfaces] rather than a list of stores, so a per-radio
/// store added later is wiped without anyone remembering to add it here: the
/// inventory test already refuses an undeclared key. Every per-radio key in
/// this repo is the surface key followed by the 10-hex radio prefix, with or
/// without a suffix, so a prefix match per surface finds all of them in both
/// backends and in the message rows.
///
/// [radioPrefix] must be exactly 10 lowercase hex. Anything else throws before
/// a single delete: an empty prefix would match every radio's data.
///
/// Returns how many keys and row groups were removed.
Future<int> wipeRadioData(String radioPrefix) async {
  if (!RegExp(r'^[0-9a-f]{10}$').hasMatch(radioPrefix)) {
    throw ArgumentError.value(
      radioPrefix,
      'radioPrefix',
      'must be the 10-hex radio key prefix',
    );
  }

  final blobs = BlobStore.instance;
  final prefixes = [
    for (final s in storageSurfaces)
      if (s.verdict == ScopingVerdict.perRadio) '${s.key}$radioPrefix',
  ];

  var removed = 0;
  for (final prefix in prefixes) {
    for (final key in await blobs.keysWithPrefix(prefix)) {
      await blobs.deleteEverywhere(key);
      removed++;
    }
  }

  for (final storeKey in await blobs.messageStoreKeys()) {
    if (prefixes.any(storeKey.startsWith)) {
      await blobs.deleteMessageRows(storeKey);
      removed++;
    }
  }

  return removed;
}

/// Deletes one radio's message history, its channel messages and its direct
/// messages, and nothing else: contacts, channels and settings stay (#1163).
///
/// For a history that is already mixed up. The owner's ruling: start fresh
/// for that radio, channels and DMs together. Same prefix rule and the same
/// refusal of anything but a 10-hex prefix as [wipeRadioData].
///
/// Returns how many keys and row groups were removed.
Future<int> wipeRadioMessageHistory(String radioPrefix) async {
  if (!RegExp(r'^[0-9a-f]{10}$').hasMatch(radioPrefix)) {
    throw ArgumentError.value(
      radioPrefix,
      'radioPrefix',
      'must be the 10-hex radio key prefix',
    );
  }

  final blobs = BlobStore.instance;
  final prefixes = ['channel_messages_$radioPrefix', 'messages_$radioPrefix'];

  // What exists now is what goes. A message saved while this runs is not in
  // the snapshot and survives, the #1128 rule (review of #1163).
  final rowSnapshot = <String, Set<String>>{
    for (final storeKey in await blobs.messageStoreKeys())
      if (prefixes.any(storeKey.startsWith))
        storeKey: await blobs.messageMergeKeys(storeKey),
  };

  var removed = 0;
  for (final prefix in prefixes) {
    for (final key in await blobs.keysWithPrefix(prefix)) {
      await blobs.deleteEverywhere(key);
      removed++;
    }
  }
  for (final entry in rowSnapshot.entries) {
    await blobs.deleteMessageRowsIn(entry.key, entry.value);
    removed++;
  }
  return removed;
}
