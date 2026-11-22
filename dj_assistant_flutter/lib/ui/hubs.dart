import 'package:flutter/material.dart';

import 'theme.dart';

/// One tab of a [Hub]: an existing page, opened by its view id.
class HubTab {
  const HubTab(this.id, this.label, this.icon, [this.pageTitle]);
  final String id, label;
  final IconData icon;

  /// The page's own fixed title, hidden under the tabs because the tab
  /// already says it. Any other title (a gig's name, a fix list) still shows.
  final String? pageTitle;

  bool repeats(String title) {
    final x = title.toLowerCase();
    return x == label.toLowerCase() || x == pageTitle?.toLowerCase();
  }
}

/// A sidebar entry that groups related pages as tabs, so the app has a few
/// clear places instead of a long list of pages.
class Hub {
  const Hub(this.id, this.label, this.icon, this.tabs);
  final String id, label;
  final IconData icon;
  final List<HubTab> tabs;

  bool owns(String viewId) => tabs.any((t) => t.id == viewId);
}

/// The app's hubs in sidebar order (Ctrl+1…4 opens them).
const hubs = <Hub>[
  Hub('hub:library', 'Library', Icons.library_music_outlined, [
    HubTab('library', 'Tracks', Icons.library_music_outlined, 'Music Library'),
    HubTab('map', 'Map', Icons.scatter_plot_outlined, 'Library Map'),
    HubTab('activity', 'Sources & scans', Icons.refresh, 'Scan Activity'),
  ]),
  Hub('hub:analysis', 'Analysis', Icons.insights_outlined, [
    HubTab('suggestions', 'Suggestions', Icons.auto_fix_high_outlined),
    HubTab('health', 'Health', Icons.favorite_outline, 'Library Health'),
    HubTab(
      'duplicates',
      'Duplicates',
      Icons.copy_all_outlined,
      'Duplicate Review',
    ),
    HubTab('upgrades', 'Upgrades', Icons.high_quality_outlined),
  ]),
  Hub('hub:crates', 'Crates', Icons.inventory_2_outlined, [
    HubTab('crates', 'Virtual crates', Icons.inventory_2_outlined),
    HubTab('discovery', 'Discovery', Icons.explore_outlined),
  ]),
  Hub('hub:prep', 'Prep & Gigs', Icons.bolt_outlined, [
    HubTab('quick', 'Quick Prep', Icons.bolt_outlined),
    HubTab('organize', 'Organise Files', Icons.build_outlined),
    HubTab('gig', 'Gig Mode', Icons.sensors),
    HubTab('gig-pack', 'Gig Pack', Icons.usb_outlined),
  ]),
];

/// The hub a page belongs to, if any. A crate or a source folder is shown as
/// part of Crates or Library in the sidebar, but without the hub's tabs.
Hub? hubOf(String viewId) => switch (viewId) {
  'crate' => hubs[2],
  'root' => hubs[0],
  _ => hubs.where((h) => h.owns(viewId)).firstOrNull,
};

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

/// The hub's tabs: one pill per page, the open one highlighted.
class HubTabs extends StatelessWidget {
  const HubTabs({super.key, required this.scope});
  final HubScope scope;

  @override
  Widget build(BuildContext context) {
    final t = DjTokens.of(context);
    final text = Theme.of(context).textTheme;
    return Wrap(
      spacing: Space.x2,
      runSpacing: Space.x2,
      children: [
        for (final tab in scope.hub.tabs)
          Builder(
            builder: (context) {
              final on = tab.id == scope.current;
              return Semantics(
                button: true,
                selected: on,
                child: Material(
                  color: on ? t.tint(t.accent, 0.16) : Colors.transparent,
                  shape: RoundedRectangleBorder(
                    borderRadius: Radii.medium,
                    side: BorderSide(
                      color: on ? t.accent : t.text.withValues(alpha: 0.12),
                    ),
                  ),
                  child: InkWell(
                    borderRadius: Radii.medium,
                    onTap: on ? null : () => scope.onSelect(tab.id),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: Space.x3,
                        vertical: Space.x2,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            tab.icon,
                            size: IconSizes.md,
                            color: on ? t.accent : t.muted,
                          ),
                          const SizedBox(width: Space.x2),
                          Text(
                            tab.label,
                            style: text.labelLarge?.copyWith(
                              color: on ? t.accent : t.text,
                              fontWeight: on
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}
