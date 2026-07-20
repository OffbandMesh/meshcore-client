import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/helpers/gif_helper.dart';
import 'package:meshcore_open/services/notification_service.dart';

// #284: notifications summarised a GIF as "Sent a GIF" using their own
// hand-rolled `^g:<id>$` regex. #282 changed the payload to a Giphy URL, which
// that regex does not match, so notifications regressed to dumping the raw URL.
// Detection must go through GifHelper.parseGif so every payload form the app
// can actually send is summarised, and so the regex cannot drift again.
void main() {
  const gifId = 'zaMiq1BvCdAVIiu3Mb';

  group('GIF payloads are summarised, not dumped raw', () {
    test('the current URL payload summarises', () {
      expect(
        NotificationService.formatNotificationText(GifHelper.encodeGif(gifId)),
        'Sent a GIF',
      );
    });

    test('a reply carrying a GIF summarises', () {
      expect(
        NotificationService.formatNotificationText(
          '@[Some Node] ${GifHelper.encodeGif(gifId)}',
        ),
        'Sent a GIF',
      );
    });

    test('a legacy g:<id> payload still summarises', () {
      expect(
        NotificationService.formatNotificationText('g:$gifId'),
        'Sent a GIF',
      );
    });

    test('a legacy g:<id> reply still summarises', () {
      expect(
        NotificationService.formatNotificationText('@[Some Node] g:$gifId'),
        'Sent a GIF',
      );
    });
  });

  group('everything else is untouched', () {
    test('a reaction still summarises', () {
      expect(
        NotificationService.formatNotificationText('r:abcd:00'),
        startsWith('Reacted '),
      );
    });

    test('ordinary text passes through unchanged', () {
      expect(
        NotificationService.formatNotificationText('hey are you there'),
        'hey are you there',
      );
    });

    test('a non-GIF URL is not mistaken for a GIF', () {
      expect(
        NotificationService.formatNotificationText('https://example.com/page'),
        'https://example.com/page',
      );
    });
  });

  group('allowlisted media URLs summarise too (#283 consistency)', () {
    test('a pasted i.giphy.com link summarises', () {
      expect(
        NotificationService.formatNotificationText(
          'https://i.giphy.com/$gifId.webp',
        ),
        'Sent a GIF',
      );
    });

    test('a pasted Tenor CDN link summarises', () {
      expect(
        NotificationService.formatNotificationText(
          'https://media.tenor.com/abc123XYZ/happy-dance.gif',
        ),
        'Sent a GIF',
      );
    });

    test('an off-allowlist image URL does NOT summarise', () {
      expect(
        NotificationService.formatNotificationText(
          'https://evil.example.com/tracker.gif',
        ),
        'https://evil.example.com/tracker.gif',
      );
    });
  });
}
