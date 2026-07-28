import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/l10n.dart';
import '../services/file_log_service.dart';

/// Shared log export for the App-log and BLE-log screens (#393, #97).
///
/// The on-disk log file ([FileLogService]) holds both the app log and BLE
/// frames as one combined stream, so either screen exports the same complete
/// file. Both screens use these helpers so their Share action can't drift.
class LogExport {
  const LogExport._();

  static bool get _isMobile =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  /// Platform-standard glyph: Android share (connected nodes), iOS square+arrow,
  /// desktop reveals the saved file (folder). #396
  static IconData get icon => defaultTargetPlatform == TargetPlatform.android
      ? Icons.share
      : _isMobile
      ? Icons.ios_share
      : Icons.folder_open;

  static String tooltip(BuildContext context) => _isMobile
      ? context.l10n.debugLog_shareLog
      : context.l10n.debugLog_openLogsFolder;

  /// Flush the on-disk log and hand it to the OS share sheet (mobile), or open
  /// the logs folder in the file manager (desktop). Shows a snackbar if file
  /// logging is unavailable (e.g. web).
  static Future<void> shareLogs(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final unavailableMessage = context.l10n.debugLog_fileLoggingUnavailable;
    final subject = context.l10n.debugLog_shareSubject;
    final file = await FileLogService.instance.flushAndGetActiveFile();
    if (file == null) {
      messenger.showSnackBar(SnackBar(content: Text(unavailableMessage)));
      return;
    }
    if (_isMobile) {
      await SharePlus.instance.share(
        ShareParams(subject: subject, files: [XFile(file.path)]),
      );
    } else {
      final dir = FileLogService.instance.logDir;
      if (dir != null) await launchUrl(Uri.file(dir.path));
    }
  }
}
