/// Web stub for [vacuumInto]. The pinned-directory migration is native-only
/// (web uses drift's OPFS/IndexedDB backend and never calls this), so this
/// exists only to keep the conditional import from pulling `dart:ffi` into the
/// web build (#363).
void vacuumInto(String source, String target) =>
    throw UnsupportedError('vacuumInto is native-only');

/// Web stub for [readStoredBlobs]; never called on web (#367).
Map<String, String> readStoredBlobs(String path) =>
    throw UnsupportedError('readStoredBlobs is native-only');
