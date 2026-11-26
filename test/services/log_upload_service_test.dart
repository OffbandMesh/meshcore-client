import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshcore_open/services/log_envelope.dart';
import 'package:meshcore_open/services/log_upload_service.dart';

final _package = Uint8List.fromList(List.generate(200, (i) => i % 256));

Future<LogUploadResult> _send(
  MockClient client, {
  String? note,
  int maxBytes = maxUploadBytes,
  Duration timeout = const Duration(seconds: 5),
}) => LogUploader(
  client: client,
  timeout: timeout,
  maxBytes: maxBytes,
).send(_package, platform: 'android', appVersion: '1.8.0+70', note: note);

void main() {
  test('sends a sealed package and returns the code', () async {
    late http.Request seen;
    final result = await _send(
      MockClient((req) async {
        seen = req;
        return http.Response('{"code":"OB-7K2QX"}', 201);
      }),
      note: '  radio dropped after 2 hops & then 50% ok  ',
    );

    expect(result, isA<LogUploadSent>());
    expect((result as LogUploadSent).code, 'OB-7K2QX');
    expect(seen.url, offbandLogUploadUrl);
    expect(seen.headers['X-Offband-Platform'], 'android');
    expect(seen.headers['X-Offband-App-Version'], '1.8.0+70');
    expect(
      Uri.decodeComponent(seen.headers['X-Offband-Note']!),
      'radio dropped after 2 hops & then 50% ok',
    );
    final body = seen.bodyBytes;
    expect(body.sublist(0, 5), [...LogEnvelope.magic, LogEnvelope.version]);
    final ownerKey = [
      for (var i = 0; i < offbandLogPublicKeyHex.length; i += 2)
        int.parse(offbandLogPublicKeyHex.substring(i, i + 2), radix: 16),
    ];
    expect(body.sublist(5, 9), LogEnvelope.keyId(ownerKey));
    expect(body.length, LogEnvelope.headerLength + _package.length + 16);
    expect(body, isNot(containsAllInOrder(_package.sublist(0, 32))));
  });

  test('a blank note sends no note header', () async {
    late http.Request seen;
    await _send(
      MockClient((req) async {
        seen = req;
        return http.Response('{"code":"OB-7K2QX"}', 201);
      }),
      note: '   ',
    );
    expect(seen.headers.containsKey('X-Offband-Note'), isFalse);
  });

  for (final (status, failure) in [
    (413, LogUploadFailure.tooLarge),
    (429, LogUploadFailure.rateLimited),
    (400, LogUploadFailure.refused),
    (411, LogUploadFailure.refused),
    (500, LogUploadFailure.server),
    (503, LogUploadFailure.server),
  ]) {
    test('HTTP $status is reported as ${failure.name}', () async {
      final result = await _send(
        MockClient((_) async => http.Response('{}', status)),
      );
      expect((result as LogUploadFailed).failure, failure);
    });
  }

  test('a stored upload with no usable code is a server failure', () async {
    for (final body in ['', 'not json', '{"code":"OB-00000"}', '{"x":1}']) {
      final result = await _send(
        MockClient((_) async => http.Response(body, 201)),
      );
      expect((result as LogUploadFailed).failure, LogUploadFailure.server);
    }
  });

  test('no network and no answer are network failures', () async {
    final offline = await _send(
      MockClient((_) async => throw http.ClientException('no route')),
    );
    expect((offline as LogUploadFailed).failure, LogUploadFailure.network);

    final silent = await _send(
      MockClient((_) => Completer<http.Response>().future),
      timeout: const Duration(milliseconds: 50),
    );
    expect((silent as LogUploadFailed).failure, LogUploadFailure.network);
  });

  test('a package over the limit is refused before anything is sent', () async {
    var requests = 0;
    final result = await _send(
      MockClient((_) async {
        requests++;
        return http.Response('{"code":"OB-7K2QX"}', 201);
      }),
      maxBytes: 100,
    );
    expect((result as LogUploadFailed).failure, LogUploadFailure.tooLarge);
    expect(requests, 0);
  });
}
