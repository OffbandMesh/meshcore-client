class GifHelper {
  /// Parse a known GIF format, which can be any of:
  /// g:GIFID
  /// https://media.giphy.com/media/GIFID/giphy.gif
  /// https://giphy.com/gifs/Optional-title-with-dashes-GIFID
  ///
  /// GIFID is a Giphy GIF ID. The https:// is optional (and
  /// can also be http://). The giphy.com/gifs form can also
  /// include a trailing slash.
  ///
  /// Returns null if text is not a valid GIF format
  static String? parseGif(String text) {
    // A reply prepends a leading `@[Name] ` mention; ignore it so a reply-gif
    // still resolves to the gif rather than plain text. Only a reply mention is
    // stripped — arbitrary text before a gif is left as text. (#232)
    final trimmed = text.trim().replaceFirst(RegExp(r'^@\[[^\]]+\]\s+'), '');
    final match = RegExp(r'^g:([A-Za-z0-9_-]+)$').firstMatch(trimmed);
    if (match != null) {
      return match.group(1);
    }
    final directUrlMatch = RegExp(
      r'^(?:https?:\/\/)?media\.giphy\.com\/media\/([A-Za-z0-9_-]+)\/giphy\.gif$',
    ).firstMatch(trimmed);
    if (directUrlMatch != null) {
      return directUrlMatch.group(1);
    }
    // Giphy understands page URLs with just the ID, or any string and a
    // dash before the ID, and redirects to a page with a dash-separated
    // title, a dash, and the ID. IDs in this form *probably* can't
    // contain dashes.
    final pageMatch = RegExp(
      r'^(?:https?:\/\/)?giphy\.com\/gifs\/(?:[^/?]*-)?([A-Za-z0-9_]+)\/?$',
    ).firstMatch(trimmed);
    if (pageMatch != null) {
      return pageMatch.group(1);
    }
    // The CDN form people actually paste out of a browser. (#283)
    final cdnMatch = RegExp(
      r'^(?:https?:\/\/)?i\.giphy\.com\/([A-Za-z0-9_-]+)\.(?:gif|webp)$',
    ).firstMatch(trimmed);
    return cdnMatch?.group(1);
  }

  /// Encode a GIF as a Giphy page URL, a format parseGif() also parses.
  ///
  /// A real URL rather than the lineage-only `g:<id>` token: recipients on
  /// stock (or any non-lineage) MeshCore client can open it, where `g:<id>`
  /// is opaque text to them. parseGif already matches this form, so Offband
  /// keeps rendering inline and legacy `g:<id>` payloads still decode. (#282)
  static String encodeGif(String gifId) {
    return 'https://giphy.com/gifs/$gifId';
  }

  /// Tenor's own CDN, the only Tenor form that is directly renderable.
  ///
  /// A `tenor.com/view/<slug>-<id>` page URL is deliberately NOT matched: the
  /// modern CDN path uses an opaque hash that cannot be derived from the page
  /// id, so resolving one needs the Tenor API. Such a link stays plain text
  /// rather than silently rendering the wrong image. (#283)
  static final RegExp _tenorMedia = RegExp(
    r'^(?:https?:\/\/)?(?:media|c)\.tenor\.com\/[A-Za-z0-9_\-\/]+\.(?:gif|webp)$',
  );

  /// The URL that renders [text], or null if it is not a GIF we will display.
  ///
  /// Rendering is restricted to an allowlist of curated GIF platforms (Giphy
  /// and Tenor). Anything off-list returns null and stays a plain tap-to-open
  /// link: auto-fetching an arbitrary URL leaks the viewer's IP and enables
  /// tracking-pixel abuse, and inline-rendering unmoderated hosts is a malware
  /// and inappropriate-content vector. Widening the allowlist is a deliberate
  /// decision, not a convenience. (#283)
  static String? resolveGifUrl(String text) {
    final gifId = parseGif(text);
    if (gifId != null) {
      return 'https://media.giphy.com/media/$gifId/giphy.gif';
    }
    final trimmed = text.trim().replaceFirst(RegExp(r'^@\[[^\]]+\]\s+'), '');
    return _tenorMedia.hasMatch(trimmed) ? trimmed : null;
  }
}
