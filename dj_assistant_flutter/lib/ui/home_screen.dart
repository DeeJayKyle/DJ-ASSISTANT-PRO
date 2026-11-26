import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/crate_tree.dart';
import '../core/serato_sync.dart';
import 'format.dart';
import 'hubs.dart';
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

    final backups = s.seratoBackups.list();
    final lastBackup = backups.isEmpty ? null : backups.first;
    final waiting = seratoSyncQueued(s.cat);
    final templates = savedTreeTemplates(s.cat);
    final settingsHub = hubs[2];

    final tiles = <BentoTile>[
      BentoTile(
        span: 2,
        color: cr.color(context),
        icon: Icons.album_outlined,
        title: 'Serato crates',
        hint: tabOf('serato')!.hint,
        onOpen: () => nav.go('serato'),
        value: fmtNumber(seratoCrates),
        caption: serato == null
            ? 'No _Serato_ folder found yet. Choose it in Settings.'
            : 'crates in ${serato.dir}',
        links: [
          page('templates', label: 'Auto-organise with a template'),
          page('crates', label: 'Smart crates'),
        ],
      ),
      BentoTile(
        span: 2,
        color: lib.color(context),
        icon: Icons.library_music_outlined,
        title: 'Library',
        hint: tabOf('library')!.hint,
        onOpen: () => nav.go('library'),
        value: fmtNumber(tracks),
        caption: tracks == 0
            ? 'No tracks yet. Add a music folder to start.'
            : '${fmtLongDuration(stats['total_duration_ms'] ?? 0)} of music · '
                  '${fmtBytes(stats['total_bytes'])} · '
                  '${plural(stats['roots'] ?? 0, 'folder')}',
        links: [
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
            '${online.isEmpty ? 'no analysers on' : '${plural(online.length, 'analyser')} on'}',
        progress: pct,
        links: [page('suggestions', label: 'Changes')],
      ),
      BentoTile(
        color: problems > 0 ? t.warn : t.ok,
        icon: Icons.favorite_outline,
        title: 'Health',
        hint: tabOf('health')!.hint,
        onOpen: () => nav.go('health'),
        value: fmtNumber(problems),
        caption: problems == 0
            ? 'No problems found.'
            : '${stats['missing'] ?? 0} missing · ${stats['errors'] ?? 0} unreadable',
      ),
      BentoTile(
        color: cr.color(context),
        icon: Icons.account_tree_outlined,
        title: 'Templates',
        hint: tabOf('templates')!.hint,
        onOpen: () => nav.go('templates'),
        value: fmtNumber(templates.length),
        caption: templates.isEmpty
            ? 'Genre → Decade → Energy and more, written into Serato.'
            : templates.keys.take(3).join(' · '),
      ),
      BentoTile(
        color: settingsHub.color(context),
        icon: Icons.archive_outlined,
        title: 'Serato backups',
        hint: tabOf('backups')!.hint,
        onOpen: () => nav.go('backups'),
        value: fmtNumber(backups.length),
        caption: lastBackup == null
            ? 'Made automatically before every change to Serato.'
            : 'latest ${fmtDateTime(lastBackup.at.millisecondsSinceEpoch)}'
                  '${waiting > 0 ? ' · ${plural(waiting, 'track')} wait for Serato to close' : ''}',
      ),
    ];

    return PageFrame(
      title: 'Home',
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
            // a dark deck-style panel; the colour is only an accent
            decoration: BoxDecoration(
              borderRadius: Radii.large,
              color: _hover ? t.panel2 : t.panel,
              border: Border.all(color: _hover ? t.tint(c, 0.55) : t.line),
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
                      Container(
                        width: 28,
                        height: 3,
                        margin: const EdgeInsets.only(bottom: Space.x3),
                        decoration: BoxDecoration(
                          color: c,
                          borderRadius: Radii.small,
                        ),
                      ),
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(Space.x2),
                            decoration: BoxDecoration(
                              color: t.tint(c, 0.14),
                              borderRadius: Radii.medium,
                            ),
                            child: Icon(w.icon, size: IconSizes.lg, color: c),
                          ),
                          const SizedBox(width: Space.x3),
                          Expanded(
                            child: Text(
                              w.title.toUpperCase(),
                              style: text.labelLarge?.copyWith(
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.8,
                                color: t.muted,
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
