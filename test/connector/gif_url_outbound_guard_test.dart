import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/helpers/gif_helper.dart';
import 'package:meshcore_open/helpers/smaz.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

// #420: Smaz send-side compression is removed. Outbound text is no longer
// compressed on any channel/contact (the toggle is gone), so
// prepare*OutboundText passes text through verbatim. Decode is deliberately
// RETAINED (Phase 2 = #421) so messages from lineage peers still sending `s:`,
// and any legacy compressed rows, keep rendering.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const gifId = 'zaMiq1BvCdAVIiu3Mb';

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
  });

  group('outbound text is never compressed (#420)', () {
    test('a GIF URL passes through unchanged', () {
      final connector = MeshCoreConnector();
      final payload = GifHelper.encodeGif(gifId);
      final prepared = connector.prepareChannelOutboundText(0, payload);
      expect(prepared, payload);
      expect(prepared.startsWith('s:'), isFalse);
      expect(GifHelper.parseGif(prepared), gifId);
    });

    test('a compressible sentence is sent verbatim, not s:-encoded', () {
      final connector = MeshCoreConnector();
      const sentence = 'hey are you there right now over and to the other end';
      final prepared = connector.prepareChannelOutboundText(0, sentence);
      expect(prepared, sentence);
      expect(prepared.startsWith('s:'), isFalse);
    });
  });

  group('receive decode is retained for lineage peers (Phase 2 = #421)', () {
    test('an s:-compressed payload still decodes back to plaintext', () {
      const sentence = 'hey are you there right now over and to the other end';
      final compressed = Smaz.encodeIfSmaller(sentence);
      // Guard the guard: the sample must actually compress, else vacuous.
      expect(compressed.startsWith('s:'), isTrue);
      expect(Smaz.tryDecodePrefixed(compressed), sentence);
    });
  });
}
