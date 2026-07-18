import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/helpers/gif_helper.dart';
import 'package:meshcore_open/helpers/smaz.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

// #282: the GIF payload is now a URL. Outbound text prep skips Smaz/Cyr2Lat for
// "structured payloads" (it keyed on `g:`/`m:`/`V1|`). A transformed GIF URL
// would arrive as opaque `s:`-prefixed base64 on a stock client, which is worse
// than the raw text this change exists to fix. Pin that it survives intact.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const gifId = 'zaMiq1BvCdAVIiu3Mb';

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
  });

  test('Smaz leaves the GIF URL intact on a Smaz-enabled channel', () async {
    final connector = MeshCoreConnector();
    await connector.setChannelSmazEnabled(0, true);

    final payload = GifHelper.encodeGif(gifId);
    final prepared = connector.prepareChannelOutboundText(0, payload);

    expect(prepared, payload);
    expect(prepared.startsWith('s:'), isFalse);
    expect(GifHelper.parseGif(prepared), gifId);
  });

  test('Smaz declines to compress a GIF URL at all', () {
    // Why the outbound `g:`/`m:`/`V1|` structured-payload guard did not need
    // widening for #282: encodeIfSmaller only swaps in the `s:`+base64 form
    // when it is genuinely smaller, and base64 overhead exceeds any dictionary
    // gain on a URL. Pinned so a future dictionary change cannot silently start
    // compressing GIF URLs into something a stock client cannot read.
    final payload = GifHelper.encodeGif(gifId);
    expect(Smaz.encodeIfSmaller(payload), payload);
  });
}
