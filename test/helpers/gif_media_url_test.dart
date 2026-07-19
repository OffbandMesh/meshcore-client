import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/helpers/gif_helper.dart';

// #283: render pasted GIF/media URLs inline, but ONLY from an allowlist of
// curated hosts (Giphy + Tenor). Anything off-list must stay a plain link and
// must never be auto-fetched: auto-loading a stranger's URL leaks the viewer's
// IP and enables tracking-pixel / read-receipt abuse, and inline-rendering
// arbitrary hosts is a malware and inappropriate-content vector.
void main() {
  const gifId = 'zaMiq1BvCdAVIiu3Mb';
  const giphyRender = 'https://media.giphy.com/media/$gifId/giphy.gif';

  group('Giphy forms all resolve to a renderable URL', () {
    test('the app payload (giphy page URL)', () {
      expect(
        GifHelper.resolveGifUrl('https://giphy.com/gifs/$gifId'),
        giphyRender,
      );
    });

    test('legacy g:<id>', () {
      expect(GifHelper.resolveGifUrl('g:$gifId'), giphyRender);
    });

    test('media.giphy.com direct asset', () {
      expect(GifHelper.resolveGifUrl(giphyRender), giphyRender);
    });

    test('i.giphy.com webp, the form users actually paste', () {
      expect(
        GifHelper.resolveGifUrl('https://i.giphy.com/$gifId.webp'),
        giphyRender,
      );
    });

    test('i.giphy.com gif', () {
      expect(
        GifHelper.resolveGifUrl('https://i.giphy.com/$gifId.gif'),
        giphyRender,
      );
    });

    test('a reply carrying a pasted Giphy URL', () {
      expect(
        GifHelper.resolveGifUrl('@[Some Node] https://i.giphy.com/$gifId.webp'),
        giphyRender,
      );
    });
  });

  group('Tenor direct media resolves to itself', () {
    test('media.tenor.com gif', () {
      const url = 'https://media.tenor.com/abc123XYZ/happy-dance.gif';
      expect(GifHelper.resolveGifUrl(url), url);
    });

    test('c.tenor.com gif', () {
      const url = 'https://c.tenor.com/abc123XYZ/tenor.gif';
      expect(GifHelper.resolveGifUrl(url), url);
    });

    test('media.tenor.com webp', () {
      const url = 'https://media.tenor.com/abc123XYZ/thing.webp';
      expect(GifHelper.resolveGifUrl(url), url);
    });
  });

  group('off-allowlist URLs must NOT render (never auto-fetch)', () {
    test('an arbitrary https image', () {
      expect(
        GifHelper.resolveGifUrl('https://evil.example.com/tracker.gif'),
        isNull,
      );
    });

    test('a lookalike host is not trusted', () {
      expect(
        GifHelper.resolveGifUrl('https://giphy.com.evil.example/$gifId.gif'),
        isNull,
      );
    });

    test('a general image host (imgur) is off-list', () {
      expect(GifHelper.resolveGifUrl('https://i.imgur.com/abc123.gif'), isNull);
    });

    test('plain text is not a GIF', () {
      expect(GifHelper.resolveGifUrl('hey are you there'), isNull);
    });

    test('a non-media URL is not a GIF', () {
      expect(GifHelper.resolveGifUrl('https://example.com/page'), isNull);
    });

    test('a tenor PAGE url does not render (needs API resolution)', () {
      // Modern Tenor CDN paths use an opaque hash not derivable from the page
      // id, so a page URL cannot be resolved without the Tenor API. Stays a
      // plain link rather than silently rendering the wrong thing.
      expect(
        GifHelper.resolveGifUrl('https://tenor.com/view/happy-dance-12345'),
        isNull,
      );
    });
  });
}
