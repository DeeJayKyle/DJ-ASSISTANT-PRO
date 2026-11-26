import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'format.dart';
import 'hubs.dart';
import 'shortcuts_sheet.dart';
import 'state.dart';
import 'theme.dart';
import 'widgets.dart';

/// A link on a bento tile: where it goes and what it does.
class BentoLink {
  const BentoLink(this.label, this.go, {this.hint, this.icon, this.color});
  final String label;
  final VoidCallback go;
  final String? hint;
  final IconData? icon;
  final Color? color;
}

/// Home: a colourful bento grid. Every tile, number and line on it is a
/// link; right-click a tile for its links as a menu.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(sessionProvider);
    final stats = ref.watch(statsProvider);
    final crates = ref.watch(cratesProvider).where((c) => c.kind != 'folder');
    final online = ref.watch(onlineOnProvider);
    final t = DjTokens.of(context);
    final nav = ref.read(viewProvider.notifier);

    BentoLink page(String id, {String? label}) {
      final tab = tabOf(id)!;
      return BentoLink(
        label ?? tab.label,
        () => nav.go(id),
        hint: tab.hint,
        icon: tab.icon,
        color: hubOf(id)?.color(context),
      );
    }

    final cr = hubs[0], lib = hubs[1], ana = hubs[1];
    final tracks = stats['tracks'] ?? 0;
    final checked =
        s.cat.db.select('SELECT COUNT(*) AS n FROM catalog_checked').first['n']
            as int;
    final problems = (stats['errors'] ?? 0) + (stats['missing'] ?? 0);
    final pct = tracks == 0 ? 0.0 : (checked / tracks).clamp(0.0, 1.0);
    final serato = s.seratoLibrary;
    var seratoCrates = 0;
    try {
      seratoCrates = serato?.crates().length ?? 0;
    } on Object {
      // unreadable folder: shown as none
    }

    final tiles = <BentoTile>[
      BentoTile(
        span: 2,
        color: lib.color(context),
        icon: lib.icon,
        title: 'Your library',
        hint: lib.hint,
        onOpen: () => nav.go('library'),
        value: fmtNumber(tracks),
        caption: tracks == 0
            ? 'No tracks yet. Add a music folder to start.'
            : '${fmtLongDuration(stats['total_duration_ms'] ?? 0)} of music · '
                  '${fmtBytes(stats['total_bytes'])} · '
                  '${stats['roots'] ?? 0} '
                  '${stats['roots'] == 1 ? 'folder' : 'folders'}',
        links: [
          page('library', label: 'Browse tracks'),
          if ((stats['roots'] ?? 0) == 0)
            page('activity', label: 'Add a music folder')
          else
            page('activity', label: 'Scan for new music'),
        ],
      ),
      BentoTile(
        color: ana.color(context),
        icon: Icons.travel_explore_outlined,
        title: 'Analysis',
        hint: tabOf('analyse')!.hint,
        onOpen: () => nav.go('analyse'),
        value: '${(pct * 100).round()}%',
        caption:
            '${fmtNumber(checked)} of ${fmtNumber(tracks)} checked online · '
            '${online.isEmpty ? 'no analysers on' : '${online.length} analyser(s) on'}',
        progress: pct,
        links: [
          page('analyse', label: 'Analyse'),
          page('suggestions', label: 'See changes'),
        ],
      ),
      BentoTile(
        color: problems > 0 ? t.warn : t.ok,
        icon: Icons.favorite_outline,
        title: 'Library health',
        hint: tabOf('health')!.hint,
        onOpen: () => nav.go('health'),
        value: fmtNumber(problems),
        caption: problems == 0
            ? 'No problems found.'
            : '${stats['missing'] ?? 0} missing · ${stats['errors'] ?? 0} unreadable',
        links: [page('health', label: 'Open Health')],
      ),
      BentoTile(
        span: 2,
        color: cr.color(context),
        icon: Icons.album_outlined,
        title: 'Serato crates',
        hint: tabOf('serato')!.hint,
        onOpen: () => nav.go('serato'),
        value: fmtNumber(seratoCrates),
        caption: serato == null
            ? 'No _Serato_ folder found yet.'
            : 'crates in ${serato.dir}',
        links: [
          page('serato', label: 'Reorganise Serato crates'),
          page('crates', label: 'Build a new crate'),
        ],
      ),
      BentoTile(
        color: cr.color(context),
        icon: cr.icon,
        title: 'Crate builder',
        hint: tabOf('crates')!.hint,
        onOpen: () => nav.go('crates'),
        value: fmtNumber(crates.length),
        caption: crates.isEmpty
            ? 'No crates yet. Start from a template.'
            : 'crates ready to save to Serato',
        links: [
          for (final c in crates.take(3))
            BentoLink(
              c.name,
              () => nav.go('crate', crateId: c.id),
              hint:
                  '${c.smart ? 'Smart' : 'Manual'} crate · '
                  '${c.trackCount} tracks',
              icon: Icons.inventory_2_outlined,
              color: cr.color(context),
            ),
          page(
            'crates',
            label: crates.isEmpty ? 'Create a crate' : 'All crates',
          ),
        ],
      ),
      BentoTile(
        span: 2,
        color: homeColor(context),
        icon: Icons.keyboard_outlined,
        title: 'Keyboard & mouse',
        hint: 'Every shortcut is listed under F1.',
        onOpen: () => showShortcuts(context),
        lines: const [
          ('Ctrl+0 · Ctrl+1…3', 'Home · Library, Analysis, Crates'),
          ('Ctrl+Tab · Ctrl+Shift+Tab', 'Next or previous tab'),
          ('Ctrl+K', 'Go to any page by name'),
          ('Alt+← / → · mouse side buttons', 'Back and forward'),
          ('Mouse wheel over tabs', 'Switch tabs'),
          ('Right-click a tile', 'Its links as a menu'),
        ],
        links: [
          BentoLink(
            'All shortcuts (F1)',
            () => showShortcuts(context),
            icon: Icons.keyboard,
            color: homeColor(context),
          ),
        ],
      ),
      BentoTile(
        color: homeColor(context),
        icon: Icons.settings_outlined,
        title: 'Settings',
        hint: 'Look, library, Serato folder, writing to files, reset.',
        onOpen: () => nav.go('settings'),
        value: '${online.length}',
        caption: online.isEmpty
            ? 'online analysers on (all off)'
            : 'online: ${online.join(', ')}',
        links: [
          BentoLink(
            'Open Settings',
            () => nav.go('settings'),
            icon: Icons.settings_outlined,
            color: homeColor(context),
            hint: 'Ctrl+,',
          ),
        ],
      ),
    ];

    return PageFrame(
      title: 'Home',
      subtitle:
          'Everything at a glance. Click any tile or link; hover for a hint.',
      child: BentoGrid(tiles: tiles),
    );
  }
}

/// Packs tiles into rows of 4, 2 or 1 columns by window width; a tile spans
/// [BentoTile.span] columns and the last tile of a short row fills it.
class BentoGrid extends StatelessWidget {
  const BentoGrid({super.key, required this.tiles});
  final List<BentoTile> tiles;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final cols = box.maxWidth >= 1000 ? 4 : (box.maxWidth >= 560 ? 2 : 1);
        final rows = <List<(BentoTile, int)>>[];
        var row = <(BentoTile, int)>[];
        var used = 0;
        for (final x in tiles) {
          final span = x.span.clamp(1, cols);
          if (used + span > cols) {
            rows.add(row);
            row = [];
            used = 0;
          }
          row.add((x, span));
          used += span;
        }
        if (row.isNotEmpty) rows.add(row);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (i, r) in rows.indexed) ...[
              if (i > 0) const SizedBox(height: Space.x3),
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final (j, (tile, span)) in r.indexed) ...[
                      if (j > 0) const SizedBox(width: Space.x3),
                      Expanded(
                        // the last tile takes what the row leaves over
                        flex: j == r.length - 1
                            ? cols -
                                  r
                                      .take(r.length - 1)
                                      .fold(0, (a, b) => a + b.$2)
                            : span,
                        child: tile,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

/// One colourful tile: icon, title, an optional big number with a caption,
/// an optional progress bar or key list, and links. The whole tile opens
/// [onOpen]; hovering lifts it and explains it; right-click lists its links.
class BentoTile extends StatefulWidget {
  const BentoTile({
    super.key,
    this.span = 1,
    required this.color,
    required this.icon,
    required this.title,
    required this.hint,
    required this.onOpen,
    this.value,
    this.caption,
    this.progress,
    this.lines = const [],
    this.links = const [],
  });
  final int span;
  final Color color;
  final IconData icon;
  final String title, hint;
  final VoidCallback onOpen;
  final String? value, caption;
  final double? progress;
  final List<(String, String)> lines;
  final List<BentoLink> links;

  @override
  State<BentoTile> createState() => _BentoTileState();
}

class _BentoTileState extends State<BentoTile> {
  bool _hover = false;

  Future<void> _menu(Offset at) async {
    final items = [
      BentoLink('Open ${widget.title}', widget.onOpen, icon: Icons.open_in_new),
      ...widget.links,
    ];
    final pick = await showMenu<int>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: [
        for (final (i, l) in items.indexed)
          PopupMenuItem(
            value: i,
            child: Row(
              children: [
                Icon(l.icon ?? Icons.arrow_outward, size: IconSizes.md),
                const SizedBox(width: Space.x3),
                Text(l.label),
              ],
            ),
          ),
      ],
    );
    if (pick != null) items[pick].go();
  }

  @override
  Widget build(BuildContext context) {
    final t = DjTokens.of(context);
    final text = Theme.of(context).textTheme;
    final c = widget.color;
    final w = widget;
    return GestureDetector(
      onSecondaryTapDown: (d) => _menu(d.globalPosition),
      child: AnimatedScale(
        scale: _hover ? 1.01 : 1,
        duration: Motion.fast(context),
        child: Material(
          color: Colors.transparent,
          child: Ink(
            decoration: BoxDecoration(
              borderRadius: Radii.large,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color.alphaBlend(t.tint(c, _hover ? 0.26 : 0.20), t.panel),
                  Color.alphaBlend(t.tint(c, 0.05), t.panel),
                ],
              ),
              border: Border.all(color: t.tint(c, _hover ? 0.70 : 0.35)),
            ),
            child: InkWell(
              borderRadius: Radii.large,
              onTap: w.onOpen,
              onHover: (v) => setState(() => _hover = v),
              child: Tooltip(
                message: '${w.hint}\nClick to open · right-click for links',
                waitDuration: const Duration(milliseconds: 600),
                child: Padding(
                  padding: const EdgeInsets.all(Space.x4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(Space.x2),
                            decoration: BoxDecoration(
                              color: t.tint(c, 0.22),
                              borderRadius: Radii.medium,
                            ),
                            child: Icon(w.icon, size: IconSizes.lg, color: c),
                          ),
                          const SizedBox(width: Space.x3),
                          Expanded(
                            child: Text(
                              w.title,
                              style: text.titleMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Icon(
                            Icons.arrow_outward,
                            size: IconSizes.md,
                            color: _hover ? c : t.faint,
                          ),
                        ],
                      ),
                      if (w.value != null) ...[
                        const SizedBox(height: Space.x3),
                        Text(
                          w.value!,
                          style: text.displaySmall?.copyWith(
                            color: c,
                            fontWeight: FontWeight.w800,
                            fontFeatures: DjType.tabular,
                          ),
                        ),
                      ],
                      if (w.caption != null) ...[
                        const SizedBox(height: Space.x1),
                        Text(
                          w.caption!,
                          style: TextStyle(color: t.muted),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                      if (w.progress != null) ...[
                        const SizedBox(height: Space.x3),
                        ClipRRect(
                          borderRadius: Radii.small,
                          child: LinearProgressIndicator(
                            value: w.progress,
                            minHeight: 8,
                            color: c,
                            backgroundColor: t.tint(c, 0.15),
                          ),
                        ),
                      ],
                      if (w.lines.isNotEmpty) ...[
                        const SizedBox(height: Space.x3),
                        for (final (k, v) in w.lines)
                          Padding(
                            padding: const EdgeInsets.only(bottom: Space.x1),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: Space.x2,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: t.tint(c, 0.16),
                                    borderRadius: Radii.small,
                                  ),
                                  child: Text(
                                    k,
                                    style: TextStyle(
                                      fontSize: DjType.small,
                                      color: c,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: Space.x2),
                                Expanded(
                                  child: Text(
                                    v,
                                    style: TextStyle(
                                      color: t.muted,
                                      fontSize: DjType.small,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                      const Spacer(),
                      if (w.links.isNotEmpty) ...[
                        const SizedBox(height: Space.x3),
                        Wrap(
                          spacing: Space.x3,
                          runSpacing: Space.x1,
                          children: [
                            for (final l in w.links)
                              DjLink(
                                label: l.label,
                                hint: l.hint,
                                icon: l.icon,
                                color: l.color ?? c,
                                onTap: l.go,
                              ),
                          ],
                        ),
                      ],
                    ],
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
