// #472: switching radios must not show the previous radio's history.
//
// The per-radio in-memory caches (_channelMessages, _conversations,
// _loadedConversationKeys) are keyed by channel index / contact key, not by
// radio. _resetConnectionHandshakeState() runs at the start of every
// connection, so it must clear them; otherwise a new radio whose store is empty
// for a channel cannot overwrite the stale entry and keeps rendering the prior
// radio's history (including its outgoing messages). On-disk stores are already
// per-radio (device+PSK), so this is purely the runtime cache.

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/models/channel_message.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
  });

  test(
    'connection reset clears the previous radio in-memory caches (#472)',
    () {
      final connector = MeshCoreConnector();

      // Seed the caches as if a prior radio's history had loaded.
      connector.channelMessagesForTest[0] = [
        ChannelMessage(
          senderName: 'PrevRadio',
          text: 'history from the other radio',
          timestamp: DateTime.fromMillisecondsSinceEpoch(1000),
          isOutgoing: true,
          status: ChannelMessageStatus.sent,
        ),
      ];
      connector.conversationsForTest['deadbeef00'] = [];
      connector.loadedConversationKeysForTest.add('deadbeef00');

      expect(connector.channelMessagesForTest, isNotEmpty);
      expect(connector.conversationsForTest, isNotEmpty);
      expect(connector.loadedConversationKeysForTest, isNotEmpty);

      // A new connection begins.
      connector.resetConnectionHandshakeStateForTest();

      expect(
        connector.channelMessagesForTest,
        isEmpty,
        reason: 'channel history cache must be dropped on reconnect',
      );
      expect(
        connector.conversationsForTest,
        isEmpty,
        reason: 'DM conversation cache must be dropped on reconnect',
      );
      expect(
        connector.loadedConversationKeysForTest,
        isEmpty,
        reason: 'loaded-conversation markers must be dropped so DMs reload',
      );
    },
  );
}
