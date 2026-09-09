import 'package:flutter/material.dart';

import '../helpers/link_handler.dart';
import 'contact_card_chip.dart';

class TranslatedMessageContent extends StatelessWidget {
  final String displayText;
  final String? originalText;
  final TextStyle style;
  final TextStyle? originalStyle;
  final bool showOriginalFirst;

  const TranslatedMessageContent({
    super.key,
    required this.displayText,
    required this.style,
    this.originalText,
    this.originalStyle,
    this.showOriginalFirst = true,
  });

  // An `@[Name]` mention anywhere in the text (leading, inline, or repeated).
  // Rendered as a chip; surrounding text stays plain. (#233)
  static final RegExp _mention = RegExp(r'@\[([^\]]+)\]');

  // A leading `@[Name] ` reply prefix.
  static final RegExp _replyPrefix = RegExp(r'^@\[([^\]]+)\]\s+');

  /// A contact share card, `<64-hex key:type:name>`, rendered as a tappable
  /// Add Contact chip rather than the raw text it used to show. (#610)
  ///
  /// This is the format real clients put on the air, confirmed because the
  /// stock app renders it as a native Add Contact button. The name is the final
  /// field and may contain colons and spaces, so it is matched greedily to the
  /// closing bracket; brackets themselves are stripped by the emitter.
  static final RegExp _contactCard = RegExp(r'<[0-9a-fA-F]{64}:\d+:[^>]*>');

  /// The name of a leading `@[Name]` reply mention, or null. Lets callers show
  /// a reply chip above content that isn't rendered as text (e.g. a reply-gif,
  /// #232).
  static String? leadingReplyName(String text) =>
      _replyPrefix.firstMatch(text.trim())?.group(1);

  /// A styled `@Name` mention chip, shared by inline text rendering and reply
  /// headers above non-text content.
  static Widget mentionChip(
    BuildContext context,
    String name,
    TextStyle style,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: scheme.onSurface.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text('@$name', style: style.copyWith(fontWeight: FontWeight.w500)),
    );
  }

  Widget _buildText(BuildContext context, String text, TextStyle textStyle) {
    final hasMention = _mention.hasMatch(text);
    final hasCard = _contactCard.hasMatch(text);
    if (!hasMention && !hasCard) {
      return LinkHandler.buildLinkifyText(
        context: context,
        text: text,
        style: textStyle,
      );
    }
    // Neither chip can be interleaved with the Linkify widget, so a message
    // containing one renders as rich text with chip spans (links inside such a
    // message are not tappable, same as the prior leading-mention path).
    // Messages with neither keep full link support above.
    //
    // Both patterns are collected and sorted by position, so a message
    // carrying a mention AND a contact card renders both in the right order.
    // They cannot overlap: a mention is `@[...]`, a card is `<...>`.
    final matches = <Match>[
      ..._mention.allMatches(text),
      ..._contactCard.allMatches(text),
    ]..sort((a, b) => a.start.compareTo(b.start));

    final spans = <InlineSpan>[];
    var last = 0;
    for (final m in matches) {
      if (m.start < last) continue;
      if (m.start > last) {
        spans.add(TextSpan(text: text.substring(last, m.start)));
      }
      final isCard = text[m.start] == '<';
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: isCard
              ? ContactCardChip(card: m.group(0)!, style: textStyle)
              : mentionChip(context, m.group(1)!, textStyle),
        ),
      );
      last = m.end;
    }
    if (last < text.length) {
      spans.add(TextSpan(text: text.substring(last)));
    }
    return Text.rich(TextSpan(children: spans), style: textStyle);
  }

  @override
  Widget build(BuildContext context) {
    final trimmedDisplay = displayText.trim();
    final trimmedOriginal = originalText?.trim();
    final shouldShowOriginal =
        trimmedOriginal != null &&
        trimmedOriginal.isNotEmpty &&
        trimmedOriginal != trimmedDisplay;
    final effectiveOriginalStyle =
        originalStyle ??
        style.copyWith(fontStyle: FontStyle.italic, fontSize: style.fontSize);
    final originalWidget = shouldShowOriginal
        ? _buildText(context, trimmedOriginal, effectiveOriginalStyle)
        : null;
    final translatedWidget = _buildText(context, trimmedDisplay, style);

    if (!shouldShowOriginal) {
      return translatedWidget;
    }

    final children = showOriginalFirst
        ? [originalWidget!, const SizedBox(height: 6), translatedWidget]
        : [translatedWidget, const SizedBox(height: 6), originalWidget!];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }
}
