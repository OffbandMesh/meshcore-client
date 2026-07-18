import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/helpers/gif_helper.dart';

// #282: the picker sends a real Giphy URL instead of the lineage-only
// `g:<code>` token, so stock / non-lineage MeshCore clients can retrieve the
// GIF instead of seeing opaque text. Offband keeps rendering inline because
// parseGif already matches this URL form.
void main() {
  const gifId = 'zaMiq1BvCdAVIiu3Mb';

  group('encodeGif emits a cross-client retrievable Giphy URL', () {
    test('emits the giphy.com page URL, not g:<code>', () {
      expect(GifHelper.encodeGif(gifId), 'https://giphy.com/gifs/$gifId');
    });

    test('what it emits round-trips back to the id through parseGif', () {
      expect(GifHelper.parseGif(GifHelper.encodeGif(gifId)), gifId);
    });
  });

  group('back-compat: legacy payloads still render', () {
    test('still parses a legacy g:<code> payload', () {
      expect(GifHelper.parseGif('g:$gifId'), gifId);
    });

    test('still parses a legacy g:<code> reply payload', () {
      expect(GifHelper.parseGif('@[Some Node] g:$gifId'), gifId);
    });

    test('parses a reply that carries the new URL form', () {
      expect(
        GifHelper.parseGif('@[Some Node] https://giphy.com/gifs/$gifId'),
        gifId,
      );
    });
  });
}
