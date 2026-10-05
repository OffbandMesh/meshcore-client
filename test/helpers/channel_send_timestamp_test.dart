import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/helpers/channel_send_timestamp.dart';

void main() {
  group('monotonicChannelSendTs', () {
    test('first send on a channel uses now', () {
      expect(monotonicChannelSendTs(1000, null), 1000);
    });

    test('bumps by 1 on a same-second collision', () {
      expect(monotonicChannelSendTs(1000, 1000), 1001);
    });

    test('uses now when it has advanced past the last send', () {
      expect(monotonicChannelSendTs(1005, 1000), 1005);
    });

    test('bumps past the last send if the clock went backwards', () {
      expect(monotonicChannelSendTs(1000, 1005), 1006);
    });

    test('a rapid burst stays strictly increasing', () {
      int? last;
      final produced = <int>[];
      // Same wall-clock second for the whole burst.
      for (var i = 0; i < 5; i++) {
        last = monotonicChannelSendTs(1000, last);
        produced.add(last);
      }
      expect(produced, [1000, 1001, 1002, 1003, 1004]);
      expect(produced.toSet().length, produced.length); // all unique
    });
  });
}
