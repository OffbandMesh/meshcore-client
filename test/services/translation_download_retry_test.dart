import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshcore_open/services/translation_service.dart';

void main() {
  final uri = Uri.parse('https://example.test/model.gguf');
  http.Request get() => http.Request('GET', uri);
  Future<void> noSleep(Duration _) async {}
  bool never() => false;

  group('isRetryableDownloadStatus', () {
    test('5xx and 429 are retryable', () {
      for (final s in [500, 502, 503, 504, 429]) {
        expect(isRetryableDownloadStatus(s), isTrue, reason: '$s');
      }
    });
    test('2xx / 3xx / terminal 4xx are not retryable', () {
      for (final s in [200, 206, 301, 400, 403, 404]) {
        expect(isRetryableDownloadStatus(s), isFalse, reason: '$s');
      }
    });
  });

  group('translationDownloadBackoff', () {
    test('exponential 1,2,4,8,16 then capped at 30', () {
      expect(translationDownloadBackoff(1), const Duration(seconds: 1));
      expect(translationDownloadBackoff(2), const Duration(seconds: 2));
      expect(translationDownloadBackoff(3), const Duration(seconds: 4));
      expect(translationDownloadBackoff(4), const Duration(seconds: 8));
      expect(translationDownloadBackoff(5), const Duration(seconds: 16));
      expect(translationDownloadBackoff(6), const Duration(seconds: 30));
    });
    test('a larger Retry-After wins, also capped at 30', () {
      expect(
        translationDownloadBackoff(1, retryAfterSeconds: 20),
        const Duration(seconds: 20),
      );
      expect(
        translationDownloadBackoff(1, retryAfterSeconds: 999),
        const Duration(seconds: 30),
      );
      // Smaller Retry-After does not shrink the exponential floor.
      expect(
        translationDownloadBackoff(4, retryAfterSeconds: 2),
        const Duration(seconds: 8),
      );
    });
  });

  group('sendModelDownloadWithRetry', () {
    test('retries a transient 503 then succeeds', () async {
      var calls = 0;
      final client = MockClient((req) async {
        calls++;
        return http.Response(
          calls == 1 ? 'busy' : 'ok',
          calls == 1 ? 503 : 200,
        );
      });
      final res = await sendModelDownloadWithRetry(
        client,
        get,
        sleep: noSleep,
        isCancelled: never,
      );
      expect(res.statusCode, 200);
      expect(calls, 2);
    });

    test('gives up after maxAttempts on persistent 503', () async {
      var calls = 0;
      final client = MockClient((req) async {
        calls++;
        return http.Response('busy', 503);
      });
      final res = await sendModelDownloadWithRetry(
        client,
        get,
        sleep: noSleep,
        isCancelled: never,
        maxAttempts: 3,
      );
      expect(res.statusCode, 503);
      expect(calls, 3);
    });

    test('does not retry a terminal 404', () async {
      var calls = 0;
      final client = MockClient((req) async {
        calls++;
        return http.Response('nope', 404);
      });
      final res = await sendModelDownloadWithRetry(
        client,
        get,
        sleep: noSleep,
        isCancelled: never,
      );
      expect(res.statusCode, 404);
      expect(calls, 1);
    });

    test('retries a network exception then succeeds', () async {
      var calls = 0;
      final client = MockClient((req) async {
        calls++;
        if (calls == 1) throw http.ClientException('connection reset');
        return http.Response('ok', 200);
      });
      final res = await sendModelDownloadWithRetry(
        client,
        get,
        sleep: noSleep,
        isCancelled: never,
      );
      expect(res.statusCode, 200);
      expect(calls, 2);
    });

    test('aborts immediately when cancelled', () async {
      final client = MockClient((req) async => http.Response('ok', 200));
      expect(
        () => sendModelDownloadWithRetry(
          client,
          get,
          sleep: noSleep,
          isCancelled: () => true,
        ),
        throwsA(isA<TranslationDownloadCancelled>()),
      );
    });
  });
}
