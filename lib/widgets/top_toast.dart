import 'dart:async';

import 'package:flutter/material.dart';

import '../utils/app_logger.dart';

/// A transient, tap-to-dismiss notification anchored to the TOP of the screen.
///
/// The app previously used bottom-anchored [SnackBar]s, which sat on top of the
/// chat composer (#638). A [SnackBar] is positioned by its [Scaffold] and can
/// only be pushed upward with a near-full-height bottom margin, which delays
/// its reveal animation and turns the whole screen into a hit-test target, so
/// this renders through the [Overlay] instead.
class TopToast {
  TopToast._();

  static const Duration _animationDuration = Duration(milliseconds: 220);
  static const Duration defaultDuration = Duration(seconds: 4);
  static const double _maxWidth = 560;

  /// Removes the toast currently on screen. Non-null only while one is visible.
  static VoidCallback? _dismissCurrent;

  /// Shows [content] at the top of the screen.
  ///
  /// When [persist] is true the toast stays until the user dismisses it, for
  /// messages that must be read rather than glimpsed (SAFELANE 6).
  static void show(
    BuildContext context, {
    required Widget content,
    Color? backgroundColor,
    Duration duration = defaultDuration,
    bool persist = false,
  }) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) {
      // SAFELANE 6: a message we cannot display must not disappear silently.
      appLogger.warn(
        'No Overlay in this context; notification was not shown',
        tag: 'TopToast',
      );
      return;
    }

    // A newer message replaces the visible one outright: two entries would
    // otherwise stack on top of each other at the same position.
    _dismissCurrent?.call();

    late final OverlayEntry entry;
    var removed = false;
    void remove() {
      if (removed) return;
      removed = true;
      entry.remove();
      if (_dismissCurrent == remove) {
        _dismissCurrent = null;
      }
    }

    entry = OverlayEntry(
      builder: (_) => _TopToastHost(
        backgroundColor: backgroundColor,
        duration: duration,
        persist: persist,
        animationDuration: _animationDuration,
        maxWidth: _maxWidth,
        onDismissed: remove,
        child: content,
      ),
    );
    _dismissCurrent = remove;
    overlay.insert(entry);
  }
}

class _TopToastHost extends StatefulWidget {
  const _TopToastHost({
    required this.child,
    required this.duration,
    required this.persist,
    required this.animationDuration,
    required this.maxWidth,
    required this.onDismissed,
    this.backgroundColor,
  });

  final Widget child;
  final Duration duration;
  final bool persist;
  final Duration animationDuration;
  final double maxWidth;
  final VoidCallback onDismissed;
  final Color? backgroundColor;

  @override
  State<_TopToastHost> createState() => _TopToastHostState();
}

class _TopToastHostState extends State<_TopToastHost>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.animationDuration,
  );
  Timer? _timer;
  bool _dismissing = false;

  @override
  void initState() {
    super.initState();
    _controller.forward();
    if (!widget.persist) {
      _timer = Timer(widget.duration, _dismiss);
    }
  }

  Future<void> _dismiss() async {
    if (_dismissing || !mounted) return;
    _dismissing = true;
    _timer?.cancel();
    try {
      await _controller.reverse();
    } on TickerCanceled {
      // Replaced by a newer toast mid-animation; that path already removed us.
      return;
    }
    if (!mounted) return;
    widget.onDismissed();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final background =
        widget.backgroundColor ??
        theme.snackBarTheme.backgroundColor ??
        theme.colorScheme.inverseSurface;
    final textStyle =
        theme.snackBarTheme.contentTextStyle ??
        theme.textTheme.titleMedium!.copyWith(
          color: theme.colorScheme.onInverseSurface,
        );

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: widget.maxWidth),
              child: SlideTransition(
                position:
                    Tween<Offset>(
                      begin: const Offset(0, -0.4),
                      end: Offset.zero,
                    ).animate(
                      CurvedAnimation(
                        parent: _controller,
                        curve: Curves.easeOutCubic,
                        reverseCurve: Curves.easeInCubic,
                      ),
                    ),
                child: FadeTransition(
                  opacity: _controller,
                  // Parity with SnackBar, which wraps its content the same way
                  // (snack_bar.dart): without liveRegion a screen reader never
                  // announces the message at all.
                  child: Semantics(
                    container: true,
                    liveRegion: true,
                    onDismiss: _dismiss,
                    child: Material(
                      color: background,
                      elevation: 6,
                      borderRadius: BorderRadius.circular(8),
                      clipBehavior: Clip.antiAlias,
                      // One recognizer for both gestures: a nested InkWell would
                      // also splash on the tap-up that ends a dismissing swipe.
                      child: GestureDetector(
                        onTap: _dismiss,
                        onVerticalDragEnd: (details) {
                          if ((details.primaryVelocity ?? 0) < 0) {
                            _dismiss();
                          }
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 14,
                          ),
                          child: DefaultTextStyle(
                            style: textStyle,
                            child: IconTheme(
                              data: IconThemeData(color: textStyle.color),
                              child: widget.child,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
