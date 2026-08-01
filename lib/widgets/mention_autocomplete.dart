import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'byte_count_input.dart';

/// A candidate name for `@`-mention autocomplete.
class MentionCandidate {
  /// The advert name EXACTLY as the device holds it, including any leading or
  /// trailing whitespace.
  ///
  /// ⚠ CROSS-REPO CONTRACT (client #497, firmware #510). The `@[name]` token
  /// carries the advert name BYTE-FOR-BYTE, unnormalised: no trimming, no
  /// Unicode normalisation, no case folding when composing it. Whitespace is
  /// part of a name's identity, and every other hop (entry, firmware memcpy,
  /// advert encode, advert parse, contact record) is already verbatim. A
  /// `.trim()` here changes the identity of the addressee and makes the
  /// mention unmatchable on the device, which is exactly the bug that stopped
  /// mentions beeping. Do not "tidy" this.
  final String name;

  /// True when this name is a recent sender in the current channel.
  final bool recent;

  /// Most-recent time this name was seen (recent candidates only).
  final DateTime? lastSeen;

  final String? _label;

  /// Display-only form. Safe to trim, because it never reaches the wire.
  String get label => _label ?? name.trim();

  const MentionCandidate({
    required this.name,
    String? label,
    required this.recent,
    this.lastSeen,
  }) : _label = label;
}

/// One row in the autocomplete dropdown.
class _Entry {
  final String label;
  final String? emoji; // leading glyph (emoji rows)
  final IconData? icon; // leading icon (mention rows)
  final String insert; // replacement text for the trigger token
  const _Entry({
    required this.label,
    this.emoji,
    this.icon,
    required this.insert,
  });
}

/// Wraps [ByteCountedTextField] with autocomplete for `@`-mentions and
/// `:emoji:` shortcodes.
///
/// - Typing `@` at the start of a word lists matching [candidates] (recent
///   senders at the bottom, contacts above) and inserts `@[ExactName] `.
/// - Typing `:` at the start of a word lists matching [emojiShortcodes] and
///   inserts the emoji character. Typing a full `:name:` auto-converts it.
///
/// Up/Down move the highlight, Tab or click selects without sending, Esc
/// dismisses. Enter accepts the highlighted item (emoji or mention) then sends;
/// dismiss with Esc first to send literal text. Either feature is disabled by
/// leaving its data empty/null.
class MentionAutocompleteField extends StatefulWidget {
  final int maxBytes;
  final TextEditingController controller;
  final FocusNode focusNode;
  final List<MentionCandidate> candidates;
  final Map<String, String>? emojiShortcodes;
  final String? hintText;
  final ValueChanged<String>? onSubmitted;
  final String Function(String)? encoder;
  final InputDecoration? decoration;

  const MentionAutocompleteField({
    super.key,
    required this.maxBytes,
    required this.controller,
    required this.focusNode,
    this.candidates = const [],
    this.emojiShortcodes,
    this.hintText,
    this.onSubmitted,
    this.encoder,
    this.decoration,
  });

  @override
  State<MentionAutocompleteField> createState() =>
      _MentionAutocompleteFieldState();
}

class _MentionAutocompleteFieldState extends State<MentionAutocompleteField> {
  final LayerLink _link = LayerLink();
  OverlayEntry? _overlay;

  List<_Entry> _matches = const [];
  int _recentStart = 0;
  int _highlighted = -1;
  int _tokenStart = -1;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChanged);
    widget.focusNode.addListener(_onFocusChanged);
    widget.focusNode.onKeyEvent = _onKey;
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    widget.focusNode.removeListener(_onFocusChanged);
    if (widget.focusNode.onKeyEvent == _onKey) {
      widget.focusNode.onKeyEvent = null;
    }
    _remove();
    super.dispose();
  }

  void _onFocusChanged() {
    if (!widget.focusNode.hasFocus) _close();
  }

  /// A "word" char (ASCII letter/digit). A trigger is only suppressed when it
  /// sits immediately after one of these (e.g. `http://`, `3:30`), so a colon
  /// right after an emoji or punctuation still opens the picker.
  static bool _isWordChar(String c) {
    final u = c.codeUnitAt(0);
    return (u >= 0x61 && u <= 0x7a) || // a-z
        (u >= 0x41 && u <= 0x5a) || // A-Z
        (u >= 0x30 && u <= 0x39); // 0-9
  }

  static bool _isShortcodeChar(String c) {
    final u = c.codeUnitAt(0);
    return (u >= 0x61 && u <= 0x7a) || // a-z
        (u >= 0x30 && u <= 0x39) || // 0-9
        c == '_' ||
        c == '+' ||
        c == '-';
  }

  void _onChanged() {
    // Cursor-driven trigger detection (same shape as multi_trigger_autocomplete's
    // invokingTrigger). It does not special-case the IME composing region,
    // fine for hardware keyboards; a known limitation for CJK/IME input, which
    // the reference package doesn't handle either.
    final value = widget.controller.value;
    final sel = value.selection;
    final text = value.text;
    if (!sel.isValid || !sel.isCollapsed) {
      _close();
      return;
    }
    final caret = sel.baseOffset;
    if (caret < 0 || caret > text.length) {
      _close();
      return;
    }

    // Auto-convert a completed :name: when the closing colon is typed.
    final shortcodes = widget.emojiShortcodes;
    if (shortcodes != null && caret >= 2 && text[caret - 1] == ':') {
      int j = caret - 2;
      while (j >= 0 && _isShortcodeChar(text[j])) {
        j--;
      }
      if (j >= 0 && text[j] == ':' && (j == 0 || !_isWordChar(text[j - 1]))) {
        final name = text.substring(j + 1, caret - 1);
        final glyph = shortcodes[name];
        if (name.isNotEmpty && glyph != null) {
          final newText = text.substring(0, j) + glyph + text.substring(caret);
          widget.controller.value = TextEditingValue(
            text: newText,
            selection: TextSelection.collapsed(offset: j + glyph.length),
          );
          _close();
          return;
        }
      }
    }

    // Walk back to a trigger char (@ or :) that begins a word.
    int i = caret - 1;
    String? trigger;
    while (i >= 0) {
      final ch = text[i];
      if (ch == '@') {
        trigger = '@';
        break;
      }
      if (ch == ':') {
        trigger = ':';
        break;
      }
      if (ch == ' ' || ch == '\n' || ch == '\t' || ch == ']') {
        break;
      }
      i--;
    }
    if (trigger == null || i < 0) {
      _close();
      return;
    }
    if (i > 0 && _isWordChar(text[i - 1])) {
      _close();
      return;
    }
    final query = text.substring(i + 1, caret);
    // No real shortcode or name is this long; avoid pathological scans.
    if (query.length > 64) {
      _close();
      return;
    }
    _tokenStart = i;
    if (trigger == '@') {
      _filterMentions(query);
    } else {
      _filterEmoji(query);
    }
  }

  void _filterMentions(String query) {
    if (widget.candidates.isEmpty) {
      _close();
      return;
    }
    final q = query.toLowerCase();
    final matched = widget.candidates.where(
      (c) => c.name.toLowerCase().startsWith(q),
    );

    final recentByName = <String, MentionCandidate>{};
    final contacts = <MentionCandidate>[];
    for (final c in matched) {
      if (c.recent) recentByName[c.name.toLowerCase()] = c;
    }
    for (final c in matched) {
      if (!c.recent && !recentByName.containsKey(c.name.toLowerCase())) {
        contacts.add(c);
      }
    }
    final recent = recentByName.values.toList();
    contacts.sort(
      (a, b) => b.name.toLowerCase().compareTo(a.name.toLowerCase()),
    );
    recent.sort((a, b) {
      final ta = a.lastSeen;
      final tb = b.lastSeen;
      if (ta == null && tb == null) {
        return b.name.toLowerCase().compareTo(a.name.toLowerCase());
      }
      if (ta == null) return -1;
      if (tb == null) return 1;
      return ta.compareTo(tb);
    });

    final combined = [...contacts, ...recent];
    if (combined.isEmpty) {
      _close();
      return;
    }
    _matches = combined
        .map(
          // label is display, insert is the wire token. They are deliberately
          // different fields: the token must carry the raw name verbatim while
          // the list may show a tidied one. (#497)
          (c) => _Entry(
            label: c.label,
            icon: c.recent ? Icons.history : Icons.person_outline,
            insert: '@[${c.name}] ',
          ),
        )
        .toList();
    _recentStart = contacts.length;
    _highlighted = _matches.length - 1;
    _show();
  }

  void _filterEmoji(String query) {
    final shortcodes = widget.emojiShortcodes;
    if (shortcodes == null || query.isEmpty) {
      _close();
      return;
    }
    for (final ch in query.split('')) {
      if (!_isShortcodeChar(ch)) {
        _close();
        return;
      }
    }
    final names = shortcodes.keys.where((k) => k.contains(query)).toList();
    if (names.isEmpty) {
      _close();
      return;
    }
    names.sort((a, b) {
      // Rank exact, then prefix, then mid-name matches; shorter names first.
      if (a == query && b != query) return -1;
      if (b == query && a != query) return 1;
      final aPrefix = a.startsWith(query);
      final bPrefix = b.startsWith(query);
      if (aPrefix != bPrefix) return aPrefix ? -1 : 1;
      final byLen = a.length.compareTo(b.length);
      if (byLen != 0) return byLen;
      return a.compareTo(b);
    });
    // Best 8, then reversed so the best sits at the bottom (nearest the input).
    final top = names.take(8).toList().reversed.toList();
    _matches = top
        .map(
          (k) => _Entry(
            label: ':$k:',
            emoji: shortcodes[k],
            insert: shortcodes[k]!,
          ),
        )
        .toList();
    _recentStart = _matches.length; // no divider for emoji
    _highlighted = _matches.length - 1;
    _show();
  }

  void _show() {
    if (_overlay == null) {
      _overlay = OverlayEntry(builder: _buildDropdown);
      Overlay.of(context).insert(_overlay!);
    } else {
      _overlay!.markNeedsBuild();
    }
  }

  void _remove() {
    _overlay?.remove();
    _overlay = null;
  }

  void _close() {
    if (_overlay != null || _matches.isNotEmpty) {
      _remove();
      _matches = const [];
      _highlighted = -1;
      _tokenStart = -1;
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (_overlay == null || _matches.isEmpty) return KeyEventResult.ignored;
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowUp) {
      if (_highlighted > 0) _highlighted--;
      _overlay!.markNeedsBuild();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      if (_highlighted < _matches.length - 1) _highlighted++;
      _overlay!.markNeedsBuild();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.tab) {
      _select(_matches[_highlighted]);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      _close();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      // Enter accepts the highlighted item (emoji or mention) like Tab, then
      // sends, so `:shrug` + Enter ships the highlighted glyph, and `@Bob` +
      // Enter inserts the mention. Tab accepts without sending; Esc dismisses
      // the dropdown to send literal text. (#231)
      if (_highlighted >= 0 && _highlighted < _matches.length) {
        _select(_matches[_highlighted]);
        widget.onSubmitted?.call(widget.controller.text);
        return KeyEventResult.handled;
      }
      final text = widget.controller.text;
      _close();
      widget.onSubmitted?.call(text);
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  void _select(_Entry entry) {
    final text = widget.controller.text;
    final caret = widget.controller.selection.baseOffset;
    if (_tokenStart < 0 || caret < _tokenStart || caret > text.length) {
      _close();
      return;
    }
    final newText =
        text.substring(0, _tokenStart) + entry.insert + text.substring(caret);
    final cursor = _tokenStart + entry.insert.length;
    widget.controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: cursor),
    );
    _close();
    widget.focusNode.requestFocus();
  }

  Widget _buildDropdown(BuildContext overlayContext) {
    final box = context.findRenderObject() as RenderBox?;
    final width = box?.size.width ?? 260.0;
    final theme = Theme.of(overlayContext);

    final children = <Widget>[];
    for (var i = 0; i < _matches.length; i++) {
      if (i == _recentStart &&
          _recentStart > 0 &&
          _recentStart < _matches.length) {
        children.add(_recentDivider(theme));
      }
      final e = _matches[i];
      final selected = i == _highlighted;
      children.add(
        InkWell(
          onTap: () => _select(e),
          child: Container(
            width: double.infinity,
            color: selected
                ? theme.colorScheme.primary.withValues(alpha: 0.14)
                : null,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                if (e.emoji != null)
                  Text(e.emoji!, style: const TextStyle(fontSize: 16))
                else
                  Icon(
                    e.icon,
                    size: 15,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    e.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: selected
                          ? FontWeight.w600
                          : FontWeight.normal,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Positioned(
      width: width,
      child: CompositedTransformFollower(
        link: _link,
        showWhenUnlinked: false,
        targetAnchor: Alignment.topLeft,
        followerAnchor: Alignment.bottomLeft,
        offset: const Offset(0, -4),
        child: TextFieldTapRegion(
          child: Material(
            elevation: 4,
            borderRadius: BorderRadius.circular(8),
            clipBehavior: Clip.antiAlias,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: SingleChildScrollView(
                reverse: true,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: children,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _recentDivider(ThemeData theme) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
      color: theme.colorScheme.surfaceContainerHighest,
      child: Text(
        'Recent',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _link,
      child: ByteCountedTextField(
        maxBytes: widget.maxBytes,
        controller: widget.controller,
        focusNode: widget.focusNode,
        hintText: widget.hintText,
        onSubmitted: widget.onSubmitted,
        encoder: widget.encoder,
        decoration: widget.decoration,
      ),
    );
  }
}
