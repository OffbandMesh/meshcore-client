import 'package:flutter/material.dart';

import '../helpers/link_handler.dart';

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
    if (!_mention.hasMatch(text)) {
      return LinkHandler.buildLinkifyText(
        context: context,
        text: text,
        style: textStyle,
      );
    }
    // Mentions can't be interleaved with the Linkify widget, so a message that
    // contains a mention renders as rich text with chip spans (links inside a
    // mention message are not tappable, same as the prior leading-mention
    // path). Messages without a mention keep full link support above.
    final spans = <InlineSpan>[];
    var last = 0;
    for (final m in _mention.allMatches(text)) {
      if (m.start > last) {
        spans.add(TextSpan(text: text.substring(last, m.start)));
      }
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: mentionChip(context, m.group(1)!, textStyle),
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
