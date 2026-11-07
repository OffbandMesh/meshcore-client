// #1103: the Edit Channel dialog must never let a hashtag channel's key be
// hand-edited, because the key derives from the name (a user report: editing
// it silently diverges the channel from everyone else on that hashtag).
// These tests pin the dialog's edit policy and the rename re-derivation.

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/channel.dart';
import 'package:meshcore_open/screens/channels_screen.dart';

void main() {
  group('channelPskEditable', () {
    test('locked for name-derived and community-derived keys', () {
      expect(channelPskEditable(ChannelType.hashtag), isFalse);
      expect(channelPskEditable(ChannelType.communityHashtag), isFalse);
    });

    test('editable for the rest', () {
      expect(channelPskEditable(ChannelType.private), isTrue);
      expect(channelPskEditable(ChannelType.public), isTrue);
      expect(channelPskEditable(ChannelType.communityPublic), isTrue);
    });
  });

  group('channelNameEditable', () {
    test('only a community hashtag locks its name', () {
      expect(channelNameEditable(ChannelType.communityHashtag), isFalse);
      expect(channelNameEditable(ChannelType.hashtag), isTrue);
      expect(channelNameEditable(ChannelType.private), isTrue);
      expect(channelNameEditable(ChannelType.public), isTrue);
      expect(channelNameEditable(ChannelType.communityPublic), isTrue);
    });
  });

  group('editedNameKeepsType', () {
    test('a hashtag channel must keep a usable # name', () {
      expect(editedNameKeepsType(ChannelType.hashtag, '#other'), isTrue);
      expect(editedNameKeepsType(ChannelType.hashtag, 'other'), isFalse);
      expect(editedNameKeepsType(ChannelType.hashtag, '#'), isFalse);
      expect(editedNameKeepsType(ChannelType.hashtag, ''), isFalse);
      // '##name' hashes differently from the '#name' everyone else derives,
      // so a double hash is refused rather than silently isolating the user.
      expect(editedNameKeepsType(ChannelType.hashtag, '##general'), isFalse);
    });

    test('non-hashtag channels are unconstrained', () {
      expect(editedNameKeepsType(ChannelType.private, 'anything'), isTrue);
      expect(editedNameKeepsType(ChannelType.public, ''), isTrue);
    });
  });

  group('rename re-derivation', () {
    test('a renamed hashtag derives exactly what adding it would', () {
      // The add flow strips the '#' before deriving; the edit flow passes the
      // '#'-prefixed name. Both must land on the same key.
      expect(
        Channel.derivePskFromHashtag('#wardriving'),
        Channel.derivePskFromHashtag('wardriving'),
      );
    });

    test('different hashtags derive different keys', () {
      expect(
        Channel.derivePskFromHashtag('#test'),
        isNot(Channel.derivePskFromHashtag('#wardriving')),
      );
    });
  });
}
