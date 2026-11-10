import 'dart:io' show File;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n/l10n.dart';
import '../services/app_debug_log_service.dart';
import '../services/app_exit_info_service.dart';
import '../services/file_log_service.dart';
import 'app_logger.dart';
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

  /// Short verb for a compound button label like "Download & save". Mobile
  /// shares via the OS sheet; desktop and web save a file (web via a browser
  /// download), so "save" fits both. (#580)
  static String get actionVerb => (!kIsWeb && _isMobile) ? 'share' : 'save';

  /// The in-memory app log as text, one line per entry in the order given.
  /// What a web export downloads and what the App log screen copies.
  static String appLogText(Iterable<AppDebugLogEntry> entries) => entries
      .map(
        (entry) =>
            '[${entry.formattedTime}] [${entry.levelLabel}] [${entry.tag}] ${entry.message}',
      )
      .join('\n');

  /// An export that failed stays on screen until dismissed, because the user
  /// needs to read it rather than glimpse it (SAFELANE 6).
  static void _showError(ScaffoldMessengerState messenger, String message) {
    messenger.showSnackBar(
      SnackBar(content: Text(message), persist: true, showCloseIcon: true),
    );
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
    final present = <File>[];
    try {
      // On mobile, take every log file rather than just the active one, and
      // the ANR traces with them (#906). Two reasons: a trace lives beside the
      // log rather than inside it, and a pointer line written once at startup
      // can rotate into `.1.log` before the user exports, which would hand
      // over a trace with its metadata line missing. Desktop keeps its
      // single-file Save As: there are no exit records off Android.
      final List<File> logs;
      if (_isMobile) {
        logs = await FileLogService.instance.flushAndGetAllFiles();
      } else {
        final active = await FileLogService.instance.flushAndGetActiveFile();
        logs = active == null ? const <File>[] : <File>[active];
      }
      final candidates = <File>[
        ...logs,
        if (_isMobile) ...await AppExitInfoService.traceFiles(),
      ];
      // Last-moment existence check. Rotation renames files underneath us and
      // a trace can be pruned, so a path collected a moment ago may already be
      // gone; handing a missing path to the share sheet fails the whole export
      // rather than one attachment.
      for (final f in candidates) {
        if (await f.exists()) present.add(f);
      }
    } catch (e) {
      appLogger.error('Collecting log files failed: $e', tag: 'LogExport');
      _showError(messenger, l10n.debugLog_exportFailed);
      return;
    }
    await _exportFile(
      messenger,
      file: present.isEmpty ? null : present.first,
      fileName: _defaultFileName,
      subject: l10n.debugLog_shareSubject,
      unavailableMessage: l10n.debugLog_logUnavailable,
      failedMessage: l10n.debugLog_exportFailed,
      savedMessage: l10n.debugLog_logSaved,
      extraFiles: present.skip(1).toList(),
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
      failedMessage: l10n.debugLog_exportFailed,
      savedMessage: l10n.debugLog_logSaved,
    );
  }

  static Future<void> _exportFile(
    ScaffoldMessengerState messenger, {
    required File? file,
    required String fileName,
    required String subject,
    required String unavailableMessage,
    required String failedMessage,
    required String savedMessage,
    List<File> extraFiles = const [],
  }) async {
    if (file == null) {
      appLogger.warn('No log file to export', tag: 'LogExport');
      _showError(messenger, unavailableMessage);
      return;
    }
    try {
      if (_isMobile) {
        await SharePlus.instance.share(
          ShareParams(
            subject: subject,
            files: [
              XFile(file.path),
              for (final extra in extraFiles) XFile(extra.path),
            ],
          ),
        );
        return;
      }
      // Desktop: let the user pick where to save the file.
      final location = await getSaveLocation(suggestedName: fileName);
      if (location == null) return; // user cancelled
      await file.copy(location.path);
    } catch (e) {
      appLogger.error('Exporting ${file.path} failed: $e', tag: 'LogExport');
      _showError(messenger, failedMessage);
      return;
    }
    messenger.showSnackBar(SnackBar(content: Text(savedMessage)));
  }

  static Future<void> _downloadOnWeb(
    BuildContext context, {
    required String content,
    required String fileName,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    if (content.isEmpty) {
      appLogger.warn('No log text to download', tag: 'LogExport');
      _showError(messenger, context.l10n.debugLog_logUnavailable);
      return;
    }
    downloadTextFile(fileName, content);
  }
}
