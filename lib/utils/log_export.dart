import 'dart:io' show File;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n/l10n.dart';
import '../services/file_log_service.dart';
import 'log_web_download.dart';

/// Shared log export for the App-log and BLE-log screens (#393, #97) and any
/// other on-disk log file (e.g. a serial capture). Per platform:
///
/// - Android / iOS: OS share sheet ([SharePlus]) with the file.
/// - Windows / macOS / Linux: native "Save As" dialog ([getSaveLocation]),
///   writing the file to a location the user picks.
/// - Web: browser download of the log text (there is no on-disk file on web).
///
/// Both log screens use these helpers so their Share action can't drift. #433
class LogExport {
  const LogExport._();

  static const _defaultFileName = 'offband-log.txt';

  static bool get _isMobile =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  /// Platform-standard action glyph: share (mobile), save (desktop),
  /// download (web).
  static IconData get icon {
    if (kIsWeb) return Icons.download;
    if (defaultTargetPlatform == TargetPlatform.android) return Icons.share;
    if (_isMobile) return Icons.ios_share;
    return Icons.save_alt;
  }

  static String tooltip(BuildContext context) {
    if (kIsWeb) return context.l10n.debugLog_downloadLog;
    return _isMobile
        ? context.l10n.debugLog_shareLog
        : context.l10n.debugLog_saveLog;
  }

  /// Export the combined on-disk app+BLE log (the App/BLE log screens). On web
  /// there is no on-disk file, so [webContent] supplies the text to download.
  static Future<void> shareLogs(
    BuildContext context, {
    String Function()? webContent,
  }) async {
    if (kIsWeb) {
      await _downloadOnWeb(
        context,
        content: webContent?.call() ?? '',
        fileName: _defaultFileName,
      );
      return;
    }
    // Resolve everything off `context` BEFORE the async gap so nothing touches a
    // possibly-deactivated widget after the await.
    final messenger = ScaffoldMessenger.of(context);
    final l10n = context.l10n;
    final file = await FileLogService.instance.flushAndGetActiveFile();
    await _exportFile(
      messenger,
      file: file,
      fileName: _defaultFileName,
      subject: l10n.debugLog_shareSubject,
      unavailableMessage: l10n.debugLog_logUnavailable,
      savedMessage: l10n.debugLog_logSaved,
    );
  }

  /// Export an already-written file (e.g. a serial capture dump). Native only;
  /// callers on web should use [shareLogs] with a `webContent` builder instead.
  static Future<void> shareFile(
    BuildContext context,
    File file, {
    String? subject,
    String? fileName,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = context.l10n;
    await _exportFile(
      messenger,
      file: file,
      fileName: fileName ?? file.uri.pathSegments.last,
      subject: subject ?? l10n.debugLog_shareSubject,
      unavailableMessage: l10n.debugLog_logUnavailable,
      savedMessage: l10n.debugLog_logSaved,
    );
  }

  static Future<void> _exportFile(
    ScaffoldMessengerState messenger, {
    required File? file,
    required String fileName,
    required String subject,
    required String unavailableMessage,
    required String savedMessage,
  }) async {
    if (file == null) {
      messenger.showSnackBar(SnackBar(content: Text(unavailableMessage)));
      return;
    }
    if (_isMobile) {
      await SharePlus.instance.share(
        ShareParams(subject: subject, files: [XFile(file.path)]),
      );
      return;
    }
    // Desktop: let the user pick where to save the file.
    final location = await getSaveLocation(suggestedName: fileName);
    if (location == null) return; // user cancelled
    await file.copy(location.path);
    messenger.showSnackBar(SnackBar(content: Text(savedMessage)));
  }

  static Future<void> _downloadOnWeb(
    BuildContext context, {
    required String content,
    required String fileName,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    if (content.isEmpty) {
      messenger.showSnackBar(
        SnackBar(content: Text(context.l10n.debugLog_logUnavailable)),
      );
      return;
    }
    downloadTextFile(fileName, content);
  }
}
