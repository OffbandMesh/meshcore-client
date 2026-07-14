import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/helpers/gif_helper.dart';

void main() {
  group('GifHelper.parseGif reply/format handling', () {
    test('g:ID form', () {
      expect(GifHelper.parseGif('g:abc123'), 'abc123');
    });

    test('reply-gif: a leading @[Name] prefix is ignored (#232)', () {
      expect(GifHelper.parseGif('@[Bob] g:abc123'), 'abc123');
      expect(GifHelper.parseGif('@[Bob Smith] g:abc123'), 'abc123');
    });

    test('arbitrary text before a gif is NOT treated as a gif', () {
      expect(GifHelper.parseGif('lol g:abc123'), isNull);
    });

    test('a reply with plain text is not a gif', () {
      expect(GifHelper.parseGif('@[Bob] hello there'), isNull);
    });

    test('media.giphy.com URL resolves', () {
      expect(
        GifHelper.parseGif('https://media.giphy.com/media/abc123/giphy.gif'),
        'abc123',
      );
    });

    test('reply + gif URL resolves', () {
      expect(
        GifHelper.parseGif(
          '@[Bob] https://media.giphy.com/media/abc123/giphy.gif',
        ),
        'abc123',
      );
    });

    test('plain text is null', () {
      expect(GifHelper.parseGif('hello world'), isNull);
    });
  });
}
