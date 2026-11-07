import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../connector/meshcore_protocol.dart';
import 'community.dart';

enum ChannelType { public, private, hashtag, communityPublic, communityHashtag }

class Channel {
  final int index;
  final String name;
  final Uint8List psk; // 16 bytes
  int unreadCount;

  Channel({
    required this.index,
    required this.name,
    required this.psk,
    this.unreadCount = 0,
  });

  String get pskHex => _bytesToHex(psk);

  bool get isEmpty => name.isEmpty && psk.every((b) => b == 0);

  /// A slot the radio answered for that holds no usable channel.
  ///
  /// Erased flash reads back as 0xFF, not 0x00, so such a record is NOT
  /// [isEmpty]: the name decodes through `allowMalformed` into U+FFFD
  /// replacement characters and the PSK is all-ones. Both halves are checked
  /// because either one being unreadable makes the record unusable as a
  /// channel identity, and the PSK is what every per-channel setting is keyed
  /// by (#1060).
  ///
  /// The client must never adopt one of these as a channel, and must never
  /// persist a list containing one over a known-good cached list.
  bool get isErased =>
      name.contains('�') || (psk.isNotEmpty && psk.every((b) => b == 0xFF));

  /// A slot that carries no channel the client should hold, for either reason.
  bool get isUnusable => isEmpty || isErased;

  bool get isPublicChannel => pskHex == publicChannelPsk;

  /// Whether [psk] is Public's fixed key. Public is known by its key, never by
  /// its name or slot.
  static bool isPublicKey(Uint8List psk) =>
      _bytesToHex(psk) == publicChannelPsk;

  /// The slot firmware reserves for Public (#1896): no other channel may be
  /// written there, even while it is empty, and Public goes nowhere else.
  static const int publicSlot = 0;

  /// Whether a hashtag join of [hashtag] means Public itself, not the hashtag
  /// channel `sha256("#public")` (owner 2026-10-28: "Of course add the real
  /// public"). The same rule as the device's `namesPublic` (firmware #1896):
  /// leading `#` and spaces and trailing spaces dropped, then "public" in any
  /// case.
  static bool hashtagMeansPublic(String hashtag) {
    final bare = hashtag
        .replaceFirst(RegExp(r'^[# ]+'), '')
        .replaceFirst(RegExp(r' +$'), '');
    return bare.toLowerCase() == 'public';
  }

  static Channel? fromFrame(Uint8List frame) {
    // CHANNEL_INFO format:
    // [0] = RESP_CODE_CHANNEL_INFO (18)
    // [1] = channel_idx
    // [2-33] = name (32 bytes, null-terminated)
    // [34-49] = psk (16 bytes)
    if (frame.length < 50) return null;
    final reader = BufferReader(frame);
    try {
      if (reader.readByte() != respCodeChannelInfo) return null;
      final index = reader.readByte();
      final name = reader.readCStringGreedy(32);
      final psk = reader.readBytes(16);
      return Channel(index: index, name: name, psk: psk);
    } catch (e) {
      return null;
    }
  }

  static Channel empty(int index) {
    return Channel(index: index, name: '', psk: Uint8List(16));
  }

  static Channel fromHex(int index, String name, String pskHex) {
    final psk = parsePskHex(pskHex);
    return Channel(index: index, name: name, psk: psk);
  }

  static Uint8List parsePskHex(String hex) {
    final cleaned = hex.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
    if (cleaned.length != 32) {
      throw const FormatException('PSK must be 32 hex characters');
    }
    final bytes = Uint8List(16);
    for (int i = 0; i < 16; i++) {
      final start = i * 2;
      bytes[i] = int.parse(cleaned.substring(start, start + 2), radix: 16);
    }
    return bytes;
  }

  /// Reference-app channel share URI:
  /// `meshcore://channel/add?name=<url-encoded>&secret=<32-hex PSK>`.
  /// Round-trips with the reference MeshCore app's channel QR. (#161)
  String toShareUri() =>
      'meshcore://channel/add?name=${Uri.encodeComponent(name)}&secret=$pskHex';

  /// Parses a channel from a reference-app share URI, or null if malformed.
  /// [index] is the local slot the caller assigns on add. (#161)
  static Channel? fromShareUri(String uri, {int index = 0}) {
    final parsed = Uri.tryParse(uri.trim());
    if (parsed == null || parsed.scheme != 'meshcore') return null;
    if (parsed.host != 'channel') return null;
    if (parsed.path.replaceAll('/', '') != 'add') return null;
    final name = parsed.queryParameters['name'];
    final secret = parsed.queryParameters['secret'];
    if (name == null || secret == null) return null;
    try {
      return Channel(index: index, name: name, psk: parsePskHex(secret));
    } catch (_) {
      return null;
    }
  }

  /// True if [uri] is a valid channel share URI. (#161)
  static bool isValidShareUri(String uri) => fromShareUri(uri) != null;

  /// Derive PSK from hashtag name using SHA256.
  /// The hashtag is normalized to include '#' prefix.
  /// Returns first 16 bytes of SHA256 hash as PSK.
  static Uint8List derivePskFromHashtag(String hashtag) {
    final name = hashtag.startsWith('#') ? hashtag : '#$hashtag';
    final hash = crypto.sha256.convert(utf8.encode(name)).bytes;
    return Uint8List.fromList(hash.sublist(0, 16));
  }

  /// Derive PSK for community public channel using HMAC-SHA256.
  /// PSK = HMAC-SHA256(K, "channel:v1:__public__")[:16]
  ///
  /// This creates a channel that is "public" only to members who have
  /// the community secret. Outsiders see only opaque IDs.
  static Uint8List deriveCommunityPublicPsk(Uint8List secret) {
    final hmac = crypto.Hmac(crypto.sha256, secret);
    final digest = hmac.convert(utf8.encode('channel:v1:__public__'));
    return Uint8List.fromList(digest.bytes.sublist(0, 16));
  }

  /// Derive PSK for community hashtag channel using HMAC-SHA256.
  /// PSK = HMAC-SHA256(K, "channel:v1:" + normalized_name)[:16]
  ///
  /// Community hashtag channels are deterministic for all members
  /// (same name => same id) but impossible to enumerate/guess without K.
  static Uint8List deriveCommunityHashtagPsk(Uint8List secret, String hashtag) {
    final normalized = _normalizeCommunityHashtag(hashtag);
    final hmac = crypto.Hmac(crypto.sha256, secret);
    final digest = hmac.convert(utf8.encode('channel:v1:$normalized'));
    return Uint8List.fromList(digest.bytes.sublist(0, 16));
  }

  /// Normalize a hashtag name for consistent community PSK derivation.
  /// Strips leading #, converts to lowercase, trims whitespace.
  static String _normalizeCommunityHashtag(String hashtag) {
    return hashtag.replaceFirst(RegExp(r'^#'), '').toLowerCase().trim();
  }

  static String formatPskHex(Uint8List psk) {
    return _bytesToHex(psk);
  }

  static String _bytesToHex(Uint8List bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static bool isCommunityChannel(ChannelType channelType) {
    switch (channelType) {
      case ChannelType.communityPublic:
      case ChannelType.communityHashtag:
        return true;
      case ChannelType.public:
      case ChannelType.private:
      case ChannelType.hashtag:
        return false;
    }
  }

  static ChannelType getChannelType(
    Channel channel,
    CommunityPskIndex communityIndex,
  ) {
    Community? community = communityIndex.getCommunityForChannel(channel);
    if (community != null) {
      if (Community.isCommunityPublicChannel(channel, community)) {
        return ChannelType.communityPublic;
      }
      return ChannelType.communityHashtag;
    }
    if (channel.isPublicChannel) {
      return ChannelType.public;
    } else if (channel.name.startsWith('#')) {
      return ChannelType.hashtag;
    }
    return ChannelType.private;
  }

  static const String publicChannelPsk = '8b3387e9c5cdea6ac9e5edbaa115cd72';
}
