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

  // A leading `@[Name]` reply mention, with or without a trailing space.
  static final RegExp _mentionPrefix = RegExp(
    r'^@\[([^\]]+)\]\s*(.*)$',
    dotAll: true,
  );

  Widget _buildText(BuildContext context, String text, TextStyle textStyle) {
    final match = _mentionPrefix.firstMatch(text);
    if (match == null) {
      return LinkHandler.buildLinkifyText(
        context: context,
        text: text,
        style: textStyle,
      );
    }
    final name = match.group(1)!;
    final rest = match.group(2)!;
    final scheme = Theme.of(context).colorScheme;
    return Text.rich(
      TextSpan(
        children: [
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: scheme.onSurface.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '@$name',
                style: textStyle.copyWith(fontWeight: FontWeight.w500),
              ),
            ),
          ),
          if (rest.isNotEmpty) TextSpan(text: ' $rest'),
        ],
      ),
      style: textStyle,
    );
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
