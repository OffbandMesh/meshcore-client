/// Naming and writing of stock-compatible config files (#574, epic #568).
library;

import 'dart:io' show File;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'log_export.dart';
import 'log_web_download.dart';

/// Characters Windows forbids in a file name, plus the path separators.
final _illegalFileNameChars = RegExp(r'[<>:"/\\|?*\x00-\x1F]');

/// Builds the file name stock uses: `<device name>_meshcore_config_<stamp>`.
///
/// Real device names contain emoji and, in at least one observed case, a
/// trailing space, so the name is sanitized for the filesystem here. The name
/// written *inside* the file is never touched: it must round-trip exactly.
String stockConfigFileName(String? deviceName, DateTime at) {
  final safeName = _sanitizeForFileName(deviceName ?? '');
  final stamp = [
    at.year.toString().padLeft(4, '0'),
    at.month.toString().padLeft(2, '0'),
    at.day.toString().padLeft(2, '0'),
  ].join('-');
  final time = [
    at.hour.toString().padLeft(2, '0'),
    at.minute.toString().padLeft(2, '0'),
    at.second.toString().padLeft(2, '0'),
  ].join();
  final prefix = safeName.isEmpty ? '' : '${safeName}_';
  return '${prefix}meshcore_config_$stamp-$time.json';
}

String _sanitizeForFileName(String name) {
  final cleaned = name.replaceAll(_illegalFileNameChars, '');
  // Windows also rejects names ending in a space or a dot.
  return cleaned.replaceAll(RegExp(r'[ .]+$'), '').trim();
}

/// Writes [json] out as [fileName], using each platform's normal mechanism:
/// the share sheet on mobile, a Save As dialog on desktop, a browser download
/// on web. Reuses [LogExport], which already owns that per-platform logic, so
/// there is only one place where export behavior can drift.
Future<void> saveStockConfigFile(
  BuildContext context, {
  required String json,
  required String fileName,
  String? subject,
}) async {
  if (kIsWeb) {
    downloadTextFile(fileName, json);
    return;
  }
  // A temp file is the handoff format LogExport works in. It holds the node's
  // private key when the identity section was included, so it is written under
  // the app's own temp directory and never anywhere shared.
  final dir = await getTemporaryDirectory();
  final file = File('${dir.path}/$fileName');
  await file.writeAsString(json, flush: true);
  if (!context.mounted) return;
  await LogExport.shareFile(
    context,
    file,
    subject: subject,
    fileName: fileName,
  );
}
