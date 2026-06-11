import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'byte_count_input.dart';

/// A candidate name for `@`-mention autocomplete.
class MentionCandidate {
  final String name;

  /// True when this name is a recent sender in the current channel.
  final bool recent;

  /// Most-recent time this name was seen (recent candidates only).
  final DateTime? lastSeen;

  const MentionCandidate({
    required this.name,
    required this.recent,
    this.lastSeen,
  });
}

/// Wraps [ByteCountedTextField] with an `@`-mention autocomplete dropdown.
///
/// Typing `@` at the start of a word opens a dropdown above the field listing
/// matching [candidates]. Recent channel senders sit at the bottom (most recent
/// closest to the input and auto-highlighted); other contacts stack above in
/// alpha order with A nearest the input. Up/Down move the highlight, Tab or
/// click selects, Esc dismisses, Enter sends. Selecting replaces the `@query`
/// with `@[ExactName] ` at the cursor.
class MentionAutocompleteField extends StatefulWidget {
  final int maxBytes;
  final TextEditingController controller;
  final FocusNode focusNode;
  final List<MentionCandidate> candidates;
  final String? hintText;
  final ValueChanged<String>? onSubmitted;
  final String Function(String)? encoder;
  final InputDecoration? decoration;

  const MentionAutocompleteField({
    super.key,
    required this.maxBytes,
    required this.controller,
    required this.focusNode,
    required this.candidates,
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

  /// Match list ordered top-to-bottom: contacts (Z..A) then recent (old..new).
  List<MentionCandidate> _matches = const [];

  /// Index in [_matches] where the recent section begins.
  int _recentStart = 0;

  /// Currently highlighted index (bottom-most by default).
  int _highlighted = -1;

  /// Index of the triggering `@` in the controller text.
  int _atIndex = -1;

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

  void _onChanged() {
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
    // Walk back from the caret to an `@` that begins a word, with no
    // whitespace (or a `]`, which would break the bracket form) in between.
    int i = caret - 1;
    while (i >= 0) {
      final ch = text[i];
      if (ch == '@') break;
      if (ch == ' ' || ch == '\n' || ch == '\t' || ch == ']') {
        _close();
        return;
      }
      i--;
    }
    if (i < 0 || text[i] != '@') {
      _close();
      return;
    }
    // `@` must begin a word: preceded by start-of-text or whitespace.
    if (i > 0) {
      final prev = text[i - 1];
      if (prev != ' ' && prev != '\n' && prev != '\t') {
        _close();
        return;
      }
    }
    _atIndex = i;
    _filter(text.substring(i + 1, caret));
  }

  void _filter(String query) {
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

    // Contacts: alpha with Z at top, A at bottom (descending).
    contacts.sort(
      (a, b) => b.name.toLowerCase().compareTo(a.name.toLowerCase()),
    );
    // Recent: oldest at top, most recent at bottom.
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
    _matches = combined;
    _recentStart = contacts.length;
    _highlighted = combined.length - 1;
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
      _atIndex = -1;
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
      final text = widget.controller.text;
      _close();
      widget.onSubmitted?.call(text);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _select(MentionCandidate c) {
    final text = widget.controller.text;
    final caret = widget.controller.selection.baseOffset;
    if (_atIndex < 0 || caret < _atIndex || caret > text.length) {
      _close();
      return;
    }
    final insertion = '@[${c.name}] ';
    final newText =
        text.substring(0, _atIndex) + insertion + text.substring(caret);
    final cursor = _atIndex + insertion.length;
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
      if (i == _recentStart && _recentStart > 0 && _recentStart < _matches.length) {
        children.add(_recentDivider(theme));
      }
      final c = _matches[i];
      final selected = i == _highlighted;
      children.add(
        InkWell(
          onTap: () => _select(c),
          child: Container(
            width: double.infinity,
            color: selected
                ? theme.colorScheme.primary.withValues(alpha: 0.14)
                : null,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Icon(
                  c.recent ? Icons.history : Icons.person_outline,
                  size: 15,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    c.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight:
                          selected ? FontWeight.w600 : FontWeight.normal,
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
                child: Column(mainAxisSize: MainAxisSize.min, children: children),
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
