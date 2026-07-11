// Web/default stub: no local filesystem, so queue-sync diagnostics fall back to
// the in-app App Debug Log only. See #51.
Future<void> appendQueueSyncLine(String msg) async {}
