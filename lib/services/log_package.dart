import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../connector/meshcore_connector.dart';
import '../utils/app_logger.dart';
import '../utils/build_info.dart';
import '../utils/log_redactor.dart';
import 'app_exit_info_service.dart';
import 'file_log_service.dart';

/// The log package every send uses (#1192): every log file and Android exit
/// trace, with passwords and PINs removed, plus `manifest.json` naming the
/// build, platform and radio. Share/Save hands over these files; Send to
/// Offband zips them.
///
/// Lines written before the redactor existed are redacted here too, so an
/// older rotated log cannot carry a password out.
class LogPackage {
  LogPackage._(this.directory, this.files);

  static const String manifestName = 'manifest.json';
  static const String tracesDir = 'traces';

  /// Holds the redacted copies. Delete with [delete] once sent.
  final Directory directory;

  /// The manifest first, then the logs oldest first, then the traces.
  final List<File> files;

  /// [logs] is newest first, as [FileLogService.flushAndGetAllFiles] returns
  /// them. Both lists default to what is on disk now.
  static Future<LogPackage> build({
    MeshCoreConnector? radio,
    List<File>? logs,
    List<File>? traces,
    Directory? into,
    DateTime Function() now = DateTime.now,
  }) async {
    final logFiles =
        logs ?? await FileLogService.instance.flushAndGetAllFiles();
    final traceFiles =
        traces ??
        (defaultTargetPlatform == TargetPlatform.android
            ? await AppExitInfoService.traceFiles()
            : const <File>[]);
    final dir = into ?? await _freshTempDir();
    final sep = Platform.pathSeparator;
    final redactor = LogRedactor();
    final written = <File>[];

    for (final log in logFiles.reversed) {
      if (!await log.exists()) continue;
      final text = utf8.decode(await log.readAsBytes(), allowMalformed: true);
      final redacted = const LineSplitter()
          .convert(text)
          .map(redactor.line)
          .join('\n');
      final out = File('${dir.path}$sep${_name(log)}');
      await out.writeAsString('$redacted\n');
      written.add(out);
    }
    if (traceFiles.isNotEmpty) {
      final traceDir = await Directory('${dir.path}$sep$tracesDir').create();
      for (final trace in traceFiles) {
        if (!await trace.exists()) continue;
        written.add(await trace.copy('${traceDir.path}$sep${_name(trace)}'));
      }
    }

    final manifest = File('${dir.path}$sep$manifestName');
    await manifest.writeAsString(
      const JsonEncoder.withIndent('  ').convert(
        manifestFor(
          radio: radio,
          createdAt: now(),
          files: [for (final f in written) _relative(dir, f)],
        ),
      ),
    );
    return LogPackage._(dir, [manifest, ...written]);
  }

  static Map<String, Object?> manifestFor({
    MeshCoreConnector? radio,
    required DateTime createdAt,
    required List<String> files,
  }) => {
    'format': 1,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'app': appLogger.appVersion,
    'commit': BuildInfo.gitSha,
    'branch': BuildInfo.gitBranch,
    'buildTime': BuildInfo.buildTime,
    'platform': kIsWeb ? 'web' : defaultTargetPlatform.name,
    'os': kIsWeb ? null : Platform.operatingSystemVersion,
    'radio': radio == null
        ? null
        : {
            'connected': radio.isConnected,
            'transport': radio.activeTransport.name,
            'model': radio.deviceModel,
            'firmware': radio.firmwareVersion,
            'firmwareVerCode': radio.firmwareVerCode,
            'offbandCaps': radio.offbandCaps,
            'offbandCaps2': radio.offbandCaps2,
          },
    'files': files,
  };

  /// Every file, at its path inside the package, in one zip.
  Future<Uint8List> zip() async {
    final archive = Archive();
    for (final f in files) {
      archive.addFile(
        ArchiveFile.bytes(_relative(directory, f), await f.readAsBytes()),
      );
    }
    return ZipEncoder().encodeBytes(archive);
  }

  Future<void> delete() async {
    try {
      await directory.delete(recursive: true);
    } catch (e) {
      appLogger.warn(
        'Removing ${directory.path} failed: $e',
        tag: 'LogPackage',
      );
    }
  }

  /// A new temp folder, after removing the ones earlier packages left: a
  /// share sheet reads its files after `share` returns, so they cannot be
  /// removed straight after sending.
  static Future<Directory> _freshTempDir() async {
    final temp = await getTemporaryDirectory();
    await for (final old in temp.list()) {
      if (old is Directory && _name(old).startsWith(_tempPrefix)) {
        await old.delete(recursive: true).catchError((_) => old);
      }
    }
    return temp.createTemp(_tempPrefix);
  }

  static const _tempPrefix = 'offband-logs-';

  static String _name(FileSystemEntity f) =>
      f.uri.pathSegments.lastWhere((s) => s.isNotEmpty);

  static String _relative(Directory dir, File f) =>
      f.path.substring(dir.path.length + 1).replaceAll('\\', '/');
}
