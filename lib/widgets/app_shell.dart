import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../services/ui_view_state_service.dart';
import '../utils/app_backgrounder.dart';
import 'quick_switch_bar.dart';

/// What the system Back button should do inside an [AppShell] (#389).
enum AppShellBackAction { closeDrawer, pop, background }

/// Shared shell for the primary views (Contacts / Channels / Map).
///
/// Owns the bottom [QuickSwitchBar] that each view previously mounted itself,
/// plus the left nav drawer: a transient slide-out on narrow layouts, and a
/// dockable pane that can be pinned open on wide ones.
///
/// The bottom bar stays a bottom bar at every width; it never becomes a rail.
class AppShell extends StatefulWidget {
  static const double wideBreakpoint = 720;
  static const double _drawerWidth = 300;

  /// Bottom bar tab to highlight. A pushed detail screen (a channel chat) still
  /// sets this so the bar stays visible; it is NOT what decides Back behavior —
  /// [isTopLevel] is. Null renders no bottom bar.
  final int? selectedIndex;

  /// Whether this is a genuine top-level landing screen — a bottom-bar tab
  /// (Contacts/Channels/Map). On a top-level screen, Back sends the app to the
  /// background; on a pushed detail screen (a channel chat, the LOS map) Back
  /// pops to the list it came from. Kept separate from [selectedIndex] so a
  /// detail can keep the bar visible without Back treating it as top-level
  /// (#389). Defaults to true.
  final bool isTopLevel;
  final ValueChanged<int>? onDestinationSelected;
  final int contactsUnreadCount;
  final int channelsUnreadCount;

  final PreferredSizeWidget? appBar;

  /// App bar that needs to know whether the panel is docked, so a pushed
  /// screen can drop its hamburger when the panel is already pinned open.
  /// Takes precedence over [appBar].
  final PreferredSizeWidget Function(BuildContext context, bool pinned)?
  appBarBuilder;

  final Widget body;
  final Widget? floatingActionButton;

  /// List content for the active view. Null renders an empty drawer body.
  final Widget? drawerContent;

  /// App-level actions, pinned to the bottom of the panel. These are not
  /// contextual, which is why they were duplicated in three screens' overflow
  /// menus before. Screen-level actions stay in their own overflow menu.
  final VoidCallback? onDisconnect;
  final VoidCallback? onSettings;

  const AppShell({
    super.key,
    required this.body,
    this.selectedIndex,
    this.isTopLevel = true,
    this.onDestinationSelected,
    this.appBar,
    this.appBarBuilder,
    this.floatingActionButton,
    this.drawerContent,
    this.onDisconnect,
    this.onSettings,
    this.contactsUnreadCount = 0,
    this.channelsUnreadCount = 0,
  });

  /// Pure back-button decision (#389), extracted so it is testable without the
  /// widget tree. An open drawer closes first; a pushed detail ([isTopLevel]
  /// false) that has a route below pops to its list; anything else — a
  /// top-level tab, or a detail with nothing to pop — backgrounds the app. A
  /// top-level tab CAN pop (the scanner sits below it) but must not, or Back
  /// would strand the user on the radio-connect screen.
  @visibleForTesting
  static AppShellBackAction backAction({
    required bool drawerOpen,
    required bool isTopLevel,
    required bool canPop,
  }) {
    if (drawerOpen) return AppShellBackAction.closeDrawer;
    if (!isTopLevel && canPop) return AppShellBackAction.pop;
    return AppShellBackAction.background;
  }

  /// Hamburger for a top-level tab's app-bar leading, used when the nav panel
  /// is NOT pinned (transient drawer). Top-level tabs must set
  /// `automaticallyImplyLeading: false` and use this instead, so the pinned
  /// desktop layout shows no leading at all rather than a dead back-arrow that
  /// only backgrounds (a no-op on desktop): the #390 eyesore. A [Builder] so
  /// `openDrawer` resolves a context beneath the Scaffold.
  static Widget drawerMenuButton() => Builder(
    builder: (context) => IconButton(
      icon: const Icon(Icons.menu),
      tooltip: MaterialLocalizations.of(context).openAppDrawerTooltip,
      onPressed: () => Scaffold.of(context).openDrawer(),
    ),
  );

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  /// System back, in priority order:
  ///   1. an open drawer closes,
  ///   2. on a pushed detail screen (a channel chat), pop back to the list it
  ///      came from,
  ///   3. on a top-level tab, send the app to the background so Android returns
  ///      to the home screen or the previous app.
  ///
  /// Top-level is decided by [AppShell.isTopLevel], NOT by whether a route can
  /// be popped: a top-level tab sits on top of the scanner, so it CAN pop, but
  /// popping would dump a connected user back onto the radio-connect list.
  /// Reaching the scanner is what Disconnect is for, not what Back is for. A
  /// detail screen keeps the bottom bar ([selectedIndex]) yet is not top-level,
  /// so Back pops it (#389).
  Future<void> _handleBack() async {
    final scaffold = _scaffoldKey.currentState;
    // Guardrail (#389): a screen marked as a pushed detail must actually be
    // poppable, or Back would fall through to backgrounding the app instead of
    // returning to its list. Catches a detail wired without a route below it.
    assert(
      widget.isTopLevel || Navigator.of(context).canPop(),
      'AppShell(isTopLevel: false) must be a pushed route so Back pops to its '
      'list',
    );
    final action = AppShell.backAction(
      drawerOpen: scaffold?.isDrawerOpen ?? false,
      isTopLevel: widget.isTopLevel,
      canPop: Navigator.of(context).canPop(),
    );
    switch (action) {
      case AppShellBackAction.closeDrawer:
        scaffold!.closeDrawer();
      case AppShellBackAction.pop:
        Navigator.of(context).pop();
      case AppShellBackAction.background:
        // Background, do NOT finish. SystemNavigator.pop() would call finish()
        // on the activity, tearing down the Flutter engine and dropping the
        // radio connection, so reopening would show a disconnected radio.
        await AppBackgrounder.moveToBackground();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _handleBack();
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isWide = constraints.maxWidth >= AppShell.wideBreakpoint;
          final pinned =
              isWide && context.watch<UiViewStateService>().navDrawerPinned;

          return pinned
              ? _buildPinned(context)
              : _buildTransient(context, isWide);
        },
      ),
    );
  }

  /// Null on detail screens, which show the panel but no bottom bar.
  Widget? _bottomBar() {
    final index = widget.selectedIndex;
    final onSelected = widget.onDestinationSelected;
    if (index == null || onSelected == null) return null;
    return SafeArea(
      top: false,
      child: QuickSwitchBar(
        selectedIndex: index,
        onDestinationSelected: onSelected,
        contactsUnreadCount: widget.contactsUnreadCount,
        channelsUnreadCount: widget.channelsUnreadCount,
      ),
    );
  }

  PreferredSizeWidget? _appBar(BuildContext context, bool pinned) {
    return widget.appBarBuilder?.call(context, pinned) ?? widget.appBar;
  }

  /// Wide + pinned: the panel is laid out beside the body, not overlaid.
  Widget _buildPinned(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      appBar: _appBar(context, true),
      body: SafeArea(
        top: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: AppShell._drawerWidth,
              child: _NavPanel(
                isWide: true,
                content: widget.drawerContent,
                onDisconnect: widget.onDisconnect,
                onSettings: widget.onSettings,
              ),
            ),
            const VerticalDivider(width: 1),
            Expanded(child: widget.body),
          ],
        ),
      ),
      floatingActionButton: widget.floatingActionButton,
      bottomNavigationBar: _bottomBar(),
    );
  }

  /// Narrow, or wide-but-unpinned: standard transient drawer. Scaffold injects
  /// the hamburger into the app bar automatically.
  Widget _buildTransient(BuildContext context, bool isWide) {
    return Scaffold(
      key: _scaffoldKey,
      appBar: _appBar(context, false),
      drawer: Drawer(
        width: AppShell._drawerWidth,
        child: _NavPanel(
          isWide: isWide,
          content: widget.drawerContent,
          onDisconnect: widget.onDisconnect,
          onSettings: widget.onSettings,
        ),
      ),
      body: widget.body,
      floatingActionButton: widget.floatingActionButton,
      bottomNavigationBar: _bottomBar(),
    );
  }
}

/// Drawer contents. The pin control appears only on wide layouts, where
/// docking the panel open is useful.
class _NavPanel extends StatelessWidget {
  final bool isWide;
  final Widget? content;
  final VoidCallback? onDisconnect;
  final VoidCallback? onSettings;

  const _NavPanel({
    required this.isWide,
    this.content,
    this.onDisconnect,
    this.onSettings,
  });

  @override
  Widget build(BuildContext context) {
    final uiState = context.watch<UiViewStateService>();
    final pinned = uiState.navDrawerPinned;

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (isWide)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      MaterialLocalizations.of(context).drawerLabel,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      pinned ? Icons.push_pin : Icons.push_pin_outlined,
                    ),
                    isSelected: pinned,
                    tooltip: pinned ? 'Unpin panel' : 'Pin panel open',
                    onPressed: () => uiState.setNavDrawerPinned(!pinned),
                  ),
                ],
              ),
            ),
          if (isWide) const Divider(height: 1),
          Expanded(child: content ?? const SizedBox.shrink()),
          if (onDisconnect != null || onSettings != null) ...[
            const Divider(height: 1),
            _Footer(onDisconnect: onDisconnect, onSettings: onSettings),
          ],
        ],
      ),
    );
  }
}

/// App-level actions pinned to the bottom of the panel.
class _Footer extends StatelessWidget {
  final VoidCallback? onDisconnect;
  final VoidCallback? onSettings;

  const _Footer({this.onDisconnect, this.onSettings});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
      child: Row(
        children: [
          if (onDisconnect != null)
            Expanded(
              child: TextButton.icon(
                // Kept visually distinct: this drops the radio connection,
                // and it was a red menu entry before the move.
                style: TextButton.styleFrom(foregroundColor: colors.error),
                icon: const Icon(Icons.logout, size: 18),
                label: Text(l10n.common_disconnect),
                onPressed: onDisconnect,
              ),
            ),
          if (onSettings != null)
            Expanded(
              child: TextButton.icon(
                icon: const Icon(Icons.settings, size: 18),
                label: Text(l10n.settings_title),
                onPressed: onSettings,
              ),
            ),
        ],
      ),
    );
  }
}
