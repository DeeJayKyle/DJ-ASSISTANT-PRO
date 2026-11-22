import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'theme.dart';

/// One tab of a [Hub]: an existing page, opened by its view id.
class HubTab {
  const HubTab(
    this.id,
    this.label,
    this.icon, {
    this.pageTitle,
    required this.hint,
    this.related = const [],
  });
  final String id, label;
  final IconData icon;

  /// The page's own fixed title, hidden under the tabs because the tab
  /// already says it. Any other title (a gig's name, a fix list) still shows.
  final String? pageTitle;

  /// What the page is for, shown when the mouse rests on its tab or link.
  final String hint;

  /// Pages worth jumping to from here (shown as links under the tabs).
  final List<String> related;

  bool repeats(String title) {
    final x = title.toLowerCase();
    return x == label.toLowerCase() || x == pageTitle?.toLowerCase();
  }
}

/// A sidebar entry that groups related pages as tabs, so the app has a few
/// clear places instead of a long list of pages. Each hub has its own colour,
/// used for its sidebar icon, its tabs and its tiles on Home.
class Hub {
  const Hub(
    this.id,
    this.label,
    this.icon,
    this.hint,
    this.dark,
    this.light,
    this.tabs,
  );
  final String id, label, hint;
  final IconData icon;
  final Color dark, light;
  final List<HubTab> tabs;

  bool owns(String viewId) => tabs.any((t) => t.id == viewId);

  /// The hub's colour for the current theme (readable on its surfaces).
  Color color(BuildContext context) =>
      Theme.of(context).brightness == Brightness.light ? light : dark;
}

/// Home: the bento overview. Not a hub; it links to every hub.
const homePage = HubTab(
  'home',
  'Home',
  Icons.dashboard_outlined,
  hint: 'Overview of your library with a link to everything. Ctrl+0',
);
const homeDark = Color(0xFF5EEAD4), homeLight = Color(0xFF0F766E);

Color homeColor(BuildContext context) =>
    Theme.of(context).brightness == Brightness.light ? homeLight : homeDark;

/// The app's hubs in sidebar order (Ctrl+1…4 opens them).
const hubs = <Hub>[
  Hub(
    'hub:library',
    'Library',
    Icons.library_music_outlined,
    'Every track you have, where it lives and how it is scanned.',
    Color(0xFF38BDF8),
    Color(0xFF0369A1),
    [
      HubTab(
        'library',
        'Tracks',
        Icons.library_music_outlined,
        pageTitle: 'Music Library',
        hint: 'Search, filter, select and edit every track. Ctrl+F searches.',
        related: ['crates', 'suggestions', 'health'],
      ),
      HubTab(
        'map',
        'Map',
        Icons.scatter_plot_outlined,
        pageTitle: 'Library Map',
        hint: 'Every analysed track by tempo and energy, coloured by key.',
        related: ['library', 'crates'],
      ),
      HubTab(
        'activity',
        'Sources & scans',
        Icons.refresh,
        pageTitle: 'Scan Activity',
        hint: 'Add music folders, scan them and run audio analysis.',
        related: ['health', 'suggestions'],
      ),
    ],
  ),
  Hub(
    'hub:analysis',
    'Analysis',
    Icons.insights_outlined,
    'Check and fix your metadata: BPM, key, genre, quality and duplicates.',
    Color(0xFFA78BFA),
    Color(0xFF6D28D9),
    [
      HubTab(
        'suggestions',
        'Suggestions',
        Icons.auto_fix_high_outlined,
        hint:
            'Proposed fixes with evidence and confidence. Approve or reject; '
            'Undo puts the old value back.',
        related: ['health', 'activity', 'library'],
      ),
      HubTab(
        'health',
        'Health',
        Icons.favorite_outline,
        pageTitle: 'Library Health',
        hint: 'Missing tags, low bitrate, unreadable and missing files.',
        related: ['suggestions', 'duplicates', 'upgrades'],
      ),
      HubTab(
        'duplicates',
        'Duplicates',
        Icons.copy_all_outlined,
        pageTitle: 'Duplicate Review',
        hint: 'Exact copies, possible duplicates and alternate versions.',
        related: ['organize', 'health'],
      ),
      HubTab(
        'upgrades',
        'Upgrades',
        Icons.high_quality_outlined,
        hint: 'Low-bitrate tracks and better copies to replace them with.',
        related: ['health', 'organize'],
      ),
    ],
  ),
  Hub(
    'hub:crates',
    'Crates',
    Icons.inventory_2_outlined,
    'Build manual and smart crates and export them to Serato or rekordbox.',
    Color(0xFFFBBF24),
    Color(0xFFB45309),
    [
      HubTab(
        'crates',
        'Virtual crates',
        Icons.inventory_2_outlined,
        pageTitle: 'Virtual Crates',
        hint: 'Manual and smart crates, templates and export.',
        related: ['discovery', 'library', 'gig-pack'],
      ),
      HubTab(
        'discovery',
        'Discovery',
        Icons.explore_outlined,
        hint: 'Tracks that fit a crate, gaps, tracklist matching, new music.',
        related: ['crates', 'map'],
      ),
    ],
  ),
  Hub(
    'hub:prep',
    'Prep & Gigs',
    Icons.bolt_outlined,
    'Prepare new downloads, organise files and play out.',
    Color(0xFFFB7185),
    Color(0xFFBE123C),
    [
      HubTab(
        'quick',
        'Quick Prep',
        Icons.bolt_outlined,
        hint: 'A fast lane for a folder of fresh downloads.',
        related: ['activity', 'suggestions'],
      ),
      HubTab(
        'organize',
        'Organise Files',
        Icons.build_outlined,
        hint: 'Opt-in: write tags, rename and move files, with preview, undo.',
        related: ['duplicates', 'upgrades'],
      ),
      HubTab(
        'gig',
        'Gig Mode',
        Icons.sensors,
        hint: 'Live: set list, requests, notes and Next up.',
        related: ['gig-pack', 'crates'],
      ),
      HubTab(
        'gig-pack',
        'Gig Pack',
        Icons.usb_outlined,
        hint: 'Copy a crate or set to a USB drive, verified.',
        related: ['gig', 'crates'],
      ),
    ],
  ),
];

/// The hub a page belongs to, if any. A crate or a source folder is shown as
/// part of Crates or Library in the sidebar, but without the hub's tabs.
Hub? hubOf(String viewId) => switch (viewId) {
  'crate' => hubs[2],
  'root' => hubs[0],
  _ => hubs.where((h) => h.owns(viewId)).firstOrNull,
};

/// The tab (or Home) with this view id.
HubTab? tabOf(String viewId) => viewId == homePage.id
    ? homePage
    : [for (final h in hubs) ...h.tabs]
          .where((t) => t.id == viewId)
          .firstOrNull;

/// The tab [step] places after [viewId] in its hub, wrapping round
/// (Ctrl+Tab / Ctrl+Shift+Tab, the mouse wheel over the tabs).
String? stepTab(String viewId, int step) {
  final h = hubOf(viewId);
  if (h == null || !h.owns(viewId)) return null;
  final i = h.tabs.indexWhere((t) => t.id == viewId);
  final n = h.tabs.length;
  return h.tabs[((i + step) % n + n) % n].id;
}

/// The shortcut that opens a hub (or Home), for hints.
String? shortcutOf(String viewId) {
  if (viewId == homePage.id) return 'Ctrl+0';
  final i = hubs.indexWhere((h) => h.tabs.first.id == viewId);
  return i < 0 ? null : 'Ctrl+${i + 1}';
}

/// Tells [PageFrame] that its page is a tab of [hub], so the header shows the
/// hub's name and tabs instead of a lone page title.
class HubScope extends InheritedWidget {
  const HubScope({
    super.key,
    required this.hub,
    required this.current,
    required this.onSelect,
    required super.child,
  });
  final Hub hub;
  final String current;
  final ValueChanged<String> onSelect;

  static HubScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<HubScope>();

  @override
  bool updateShouldNotify(HubScope old) =>
      old.hub != hub || old.current != current;
}

/// The hub's tabs: one pill per page in the hub's colour, the open one
/// filled. Hovering a tab explains it; the mouse wheel over the row steps
/// through the tabs.
class HubTabs extends StatelessWidget {
  const HubTabs({super.key, required this.scope});
  final HubScope scope;

  @override
  Widget build(BuildContext context) {
    final t = DjTokens.of(context);
    final text = Theme.of(context).textTheme;
    final c = scope.hub.color(context);
    return Listener(
      onPointerSignal: (e) {
        if (e is! PointerScrollEvent) return;
        final d = e.scrollDelta.dy + e.scrollDelta.dx;
        if (d == 0) return;
        final next = stepTab(scope.current, d > 0 ? 1 : -1);
        if (next != null) scope.onSelect(next);
      },
      child: Wrap(
        spacing: Space.x2,
        runSpacing: Space.x2,
        children: [
          for (final (i, tab) in scope.hub.tabs.indexed)
            Builder(
              builder: (context) {
                final on = tab.id == scope.current;
                final key = i == 0 ? '${shortcutOf(tab.id)} · ' : '';
                return Tooltip(
                  message:
                      '${tab.hint}\n${key}Ctrl+Tab: next tab · '
                      'mouse wheel over the tabs',
                  waitDuration: const Duration(milliseconds: 350),
                  child: Semantics(
                    button: true,
                    selected: on,
                    child: Material(
                      color: on ? t.tint(c, 0.20) : t.tint(c, 0.05),
                      shape: StadiumBorder(
                        side: BorderSide(color: on ? c : t.tint(c, 0.30)),
                      ),
                      child: InkWell(
                        customBorder: const StadiumBorder(),
                        onTap: on ? null : () => scope.onSelect(tab.id),
                        hoverColor: t.tint(c, 0.12),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: Space.x4,
                            vertical: Space.x2,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(tab.icon, size: IconSizes.md, color: c),
                              const SizedBox(width: Space.x2),
                              Text(
                                tab.label,
                                style: text.labelLarge?.copyWith(
                                  color: on ? c : t.text,
                                  fontWeight: on
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}

/// "See also": links to the pages related to the open tab.
class RelatedLinks extends StatelessWidget {
  const RelatedLinks({super.key, required this.scope});
  final HubScope scope;

  @override
  Widget build(BuildContext context) {
    final t = DjTokens.of(context);
    final tab = tabOf(scope.current);
    if (tab == null || tab.related.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: Space.x3,
      runSpacing: Space.x1,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          'See also',
          style: TextStyle(color: t.faint, fontSize: DjType.small),
        ),
        for (final id in tab.related)
          if (tabOf(id) case final x?)
            DjLink(
              label: x.label,
              hint: x.hint,
              color: hubOf(id)?.color(context),
              onTap: () => scope.onSelect(id),
            ),
      ],
    );
  }
}

/// A hyperlink: coloured text that underlines on hover, shows a hand cursor
/// and explains where it goes. Enter or Space opens it from the keyboard.
class DjLink extends StatefulWidget {
  const DjLink({
    super.key,
    required this.label,
    required this.onTap,
    this.hint,
    this.color,
    this.icon,
    this.style,
  });
  final String label;
  final String? hint;
  final Color? color;
  final IconData? icon;
  final TextStyle? style;
  final VoidCallback onTap;

  @override
  State<DjLink> createState() => _DjLinkState();
}

class _DjLinkState extends State<DjLink> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = DjTokens.of(context);
    final c = widget.color ?? t.accent;
    final style = (widget.style ?? const TextStyle(fontSize: DjType.body))
        .copyWith(
          color: c,
          fontWeight: FontWeight.w600,
          decoration: _hover ? TextDecoration.underline : TextDecoration.none,
          decorationColor: c,
        );
    Widget link = InkWell(
      onTap: widget.onTap,
      onHover: (v) => setState(() => _hover = v),
      borderRadius: Radii.small,
      mouseCursor: SystemMouseCursors.click,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.icon != null) ...[
              Icon(widget.icon, size: IconSizes.sm, color: c),
              const SizedBox(width: Space.x1),
            ],
            Flexible(
              child: Text(
                widget.label,
                style: style,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            AnimatedOpacity(
              opacity: _hover ? 1 : 0,
              duration: const Duration(milliseconds: 120),
              child: Icon(Icons.arrow_outward, size: 13, color: c),
            ),
          ],
        ),
      ),
    );
    if (widget.hint != null) {
      link = Tooltip(
        message: widget.hint,
        waitDuration: const Duration(milliseconds: 350),
        child: link,
      );
    }
    return Semantics(link: true, label: widget.label, child: link);
  }
}
