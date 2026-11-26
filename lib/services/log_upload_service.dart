import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../utils/app_logger.dart';
import 'log_envelope.dart';

/// Offband's log key (#1216). Only the matching private key, held by the
/// owner, can open an upload.
const String offbandLogPublicKeyHex =
    'bfe27e2ee77e7c80d4aa9b546e3f870f979df2a5943a3fe9178d0a733883e742';

final Uri offbandLogUploadUrl = Uri.parse('https://logs.offband.app/upload');

/// The intake refuses anything larger (OffbandMesh/log-intake README).
const int maxUploadBytes = 25 * 1024 * 1024;

final RegExp _codePattern = RegExp(
  r'^OB-[23456789ABCDEFGHJKMNPQRSTUVWXYZ]{5}$',
);

enum LogUploadFailure { network, tooLarge, rateLimited, refused, server }

sealed class LogUploadResult {
  const LogUploadResult();
}

class LogUploadSent extends LogUploadResult {
  const LogUploadSent(this.code);
  final String code;
}

class LogUploadFailed extends LogUploadResult {
  const LogUploadFailed(this.failure, this.detail);
  final LogUploadFailure failure;

  /// What went wrong, for the log. The screen shows [failure] in words.
  final String detail;
}

/// Seals a zipped log package and sends it to the Offband intake (#1209).
/// Never throws: every failure comes back as [LogUploadFailed], so the screen
/// can keep the package and offer Retry.
class LogUploader {
  LogUploader({
    http.Client? client,
    Uri? endpoint,
    List<int>? publicKey,
    this.timeout = const Duration(seconds: 90),
    this.maxBytes = maxUploadBytes,
  }) : _client = client ?? http.Client(),
       _endpoint = endpoint ?? offbandLogUploadUrl,
       _publicKey = publicKey ?? _hex(offbandLogPublicKeyHex);

  final http.Client _client;
  final Uri _endpoint;
  final List<int> _publicKey;
  final Duration timeout;
  final int maxBytes;

  static List<int> _hex(String hex) => [
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ];

  Future<LogUploadResult> send(
    Uint8List package, {
    required String platform,
    required String appVersion,
    String? note,
  }) async {
    final result = await _send(package, platform, appVersion, note);
    if (result is LogUploadFailed) {
      appLogger.warn(
        'Send to Offband failed (${result.failure.name}): ${result.detail}',
        tag: 'LogUpload',
      );
    } else if (result is LogUploadSent) {
      appLogger.info(
        'Sent logs to Offband as ${result.code}',
        tag: 'LogUpload',
      );
    }
    return result;
  }

  Future<LogUploadResult> _send(
    Uint8List package,
    String platform,
    String appVersion,
    String? note,
  ) async {
    final Uint8List sealed;
    try {
      sealed = await LogEnvelope.seal(package, _publicKey);
    } catch (e) {
      return LogUploadFailed(LogUploadFailure.refused, 'could not seal: $e');
    }
    if (sealed.length > maxBytes) {
      return LogUploadFailed(
        LogUploadFailure.tooLarge,
        '${sealed.length} bytes is over the $maxBytes limit',
      );
    }
    final trimmed = note?.trim();
    final http.Response res;
    try {
      res = await _client
          .post(
            _endpoint,
            headers: {
              'Content-Type': 'application/octet-stream',
              'X-Offband-Platform': platform,
              'X-Offband-App-Version': appVersion,
              if (trimmed != null && trimmed.isNotEmpty)
                'X-Offband-Note': Uri.encodeComponent(trimmed),
            },
            body: sealed,
          )
          .timeout(timeout);
    } on TimeoutException {
      return LogUploadFailed(
        LogUploadFailure.network,
        'no answer in ${timeout.inSeconds}s',
      );
    } catch (e) {
      return LogUploadFailed(LogUploadFailure.network, '$e');
    }

    switch (res.statusCode) {
      case 201:
        final code = _codeFrom(res.body);
        return code == null
            ? LogUploadFailed(
                LogUploadFailure.server,
                'stored, but the reply had no code: ${res.body}',
              )
            : LogUploadSent(code);
      case 413:
        return const LogUploadFailed(LogUploadFailure.tooLarge, 'HTTP 413');
      case 429:
        return const LogUploadFailed(LogUploadFailure.rateLimited, 'HTTP 429');
      case 400 || 411:
        return LogUploadFailed(
          LogUploadFailure.refused,
          'HTTP ${res.statusCode}: ${res.body}',
        );
      default:
        return LogUploadFailed(
          LogUploadFailure.server,
          'HTTP ${res.statusCode}: ${res.body}',
        );
    }
  }

  static String? _codeFrom(String body) {
    try {
      final code = (jsonDecode(body) as Map<String, dynamic>)['code'];
      return code is String && _codePattern.hasMatch(code) ? code : null;
    } catch (_) {
      return null;
    }
  }
}
