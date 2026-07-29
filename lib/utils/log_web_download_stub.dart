/// Native no-op: browser download only exists on web. Never called on native
/// (callers guard with `kIsWeb`). #433
void downloadTextFile(String fileName, String content) {}
