import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/session.dart';
import '../core/crates.dart';
import '../core/export.dart';
import '../core/json.dart';
import '../core/library.dart';
import '../core/library_edit.dart';
import '../core/rules.dart';
import 'format.dart';
import 'rules_ui.dart';
import 'state.dart';
import 'theme.dart';
import 'track_detail.dart';
import 'widgets.dart';
import 'crates_screen.dart';
import 'write_dialog.dart';

/// Joins WHERE fragments with AND.
(String, List<Object?>)? andWhere(List<(String, List<Object?>)?> parts) {
  final p = parts.whereType<(String, List<Object?>)>().toList();
  if (p.isEmpty) return null;
  return (
    p.map((x) => '(${x.$1})').join(' AND '),
    [for (final x in p) ...x.$2],
  );
}

/// The library query for the current view (crate or folder), text and filters.
TrackQuery libraryTrackQuery(
  AppSession s,
  LibraryQuery q, {
  int? crateId,
  int? rootId,
  int offset = 0,
  int limit = 200,
}) {
  final f = cleanRuleSet(q.filters);
  return TrackQuery(
    text: q.text.trim().isEmpty ? null : q.text.trim(),
    rootId: rootId,
    sort: q.sort,
    desc: q.desc,
    offset: offset,
    limit: limit,
    extraWhere: andWhere([
      if (crateId != null) s.crates.membership(crateId),
      if (f != null) compileRules(f, s.library.lowBitrateKbps),
    ]),
  );
}

class _Col {
  const _Col(
    this.id,
    this.label,
    this.width, {
    this.sort,
    this.flex = 0,
    this.minTable = 0,
  });
  final String id, label;
  final double width;
  final String? sort;
  final int flex, minTable;
}

const _cols = [
  _Col('title', 'Title', 170, sort: 'title', flex: 16),
  _Col('artist', 'Artist', 120, sort: 'artist', flex: 12),
  _Col('genre', 'Genre', 90, sort: 'genre', flex: 8, minTable: 1050),
  _Col('year', 'Year', 52, sort: 'year', minTable: 640),
  _Col('bpm', 'BPM', 70, sort: 'bpm', minTable: 720),
  _Col('key', 'Key', 60, sort: 'key', minTable: 780),
  _Col('energy', 'Energy', 70, sort: 'energy', minTable: 560),
  _Col('rating', 'Rating', 74, sort: 'rating', minTable: 1180),
  _Col('time', 'Time', 54, sort: 'duration', minTable: 980),
  _Col('format', 'Format', 90, sort: 'format', minTable: 880),
  _Col('bitrate', 'Bitrate', 104, sort: 'bitrate'),
];

class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key, this.crateId, this.rootId});
  final int? crateId, rootId;
  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  static const page = 200;
  final _pages = <int, List<TrackRow>>{};
  int? _total;
  final selected = <int>{};
  int? focus, _anchor;
  final _search = TextEditingController();
  final _quick = <String, QuickOption?>{};
  LibraryQuery _sub = const LibraryQuery();
  String _key = '';

  bool get _scoped => widget.crateId != null || widget.rootId != null;
  LibraryQuery get q => _scoped ? _sub : ref.watch(libraryQueryProvider);

  void setQ(LibraryQuery v) {
    if (_scoped) {
      setState(() => _sub = v);
    } else {
      ref.read(libraryQueryProvider.notifier).set(v);
    }
  }

  @override
  void initState() {
    super.initState();
    _search.text = _scoped ? '' : ref.read(libraryQueryProvider).text;
  }

  LibraryQuery _effective(LibraryQuery base) {
    final quick = [for (final o in _quick.values) ?o?.node];
    final f = base.filters ?? emptyRuleSet();
    final rules = (f['rules'] as List?)?.cast<Node>() ?? const <Node>[];
    final combined = {
      'match': 'all',
      'rules': [
        ...quick,
        if (f['match'] == 'any' && rules.isNotEmpty)
          {'kind': 'group', 'match': 'any', 'rules': rules}
        else
          ...rules,
      ],
      'exclude': f['exclude'] ?? const [],
    };
    return base.copyWith(filters: combined);
  }

  TrackRow? rowAt(AppSession s, LibraryQuery eff, int i) {
    final p = i ~/ page;
    final rows = _pages[p] ??= s.library
        .search(
          libraryTrackQuery(
            s,
            eff,
            crateId: widget.crateId,
            rootId: widget.rootId,
            offset: p * page,
            limit: page,
          ),
        )
        .rows;
    return i % page < rows.length ? rows[i % page] : null;
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(sessionProvider);
    final version = ref.watch(versionProvider);
    final notation = '${ref.watch(settingsProvider)['key_notation']}';
    final crates = ref.watch(cratesProvider);
    final crate = widget.crateId == null
        ? null
        : crates.where((c) => c.id == widget.crateId).firstOrNull;
    final root = widget.rootId == null
        ? null
        : ref
              .watch(rootsProvider)
              .where((r) => r.id == widget.rootId)
              .firstOrNull;
    final base = q;
    final eff = _effective(base);
    final key =
        '$version|${base.text}|${base.sort}|${base.desc}|${eff.filters}|${widget.crateId}|${widget.rootId}';
    String? error;
    if (key != _key) {
      _key = key;
      _pages.clear();
      try {
        final first = s.library.search(
          libraryTrackQuery(
            s,
            eff,
            crateId: widget.crateId,
            rootId: widget.rootId,
            limit: page,
          ),
        );
        _pages[0] = first.rows;
        _total = first.total;
      } on Object catch (e) {
        error = '$e';
        _total = 0;
      }
    }
    final t = DjTokens.of(context);
    final stats = ref.watch(statsProvider);
    if (!_scoped && (stats['roots'] ?? 0) == 0) {
      return EmptyState(
        icon: Icons.library_music_outlined,
        title:
            'Welcome, ${ref.watch(accountsProvider).accounts.where((a) => a.id == ref.watch(accountsProvider).currentId).firstOrNull?.name ?? 'DJ'}',
        message: 'Add the folders that hold your music. DJ Assistant reads them to build a searchable catalogue on this computer. It never changes, moves or deletes your files, and never writes to Serato.',
        action: FilledButton.icon(
          onPressed: () => addMusicFolders(ref),
          icon: const Icon(Icons.create_new_folder_outlined),
          label: const Text('Add music folders'),
        ),
      );
    }
    final title = crate?.name ?? root?.label ?? root?.path ?? 'Music Library';
    final sub = crate != null
        ? (crate.smart
              ? 'Smart crate · ${crate.rules == null ? '' : [...((crate.rules!['rules'] as List?) ?? const []).cast<Node>().map(describeRule), ...((crate.rules!['exclude'] as List?) ?? const []).cast<Node>().map((r) => 'not ${describeRule(r)}')].join(crate.rules!['match'] == 'all' ? ', ' : ' or ')}'
              : 'Manual crate — tracks are referenced, never copied or moved.')
        : root != null
        ? '${root.path} · ${root.status == 'offline' ? 'offline' : 'online'}'
        : 'Your local DJ music collection for Serato DJ';
    final scanning = s.lastScan?.state == 'running';
    final activeRules =
        countRules(cleanRuleSet(base.filters)) +
        _quick.values.whereType<QuickOption>().length;
    final filters = base.filters;
    final rules = (filters?['rules'] as List?)?.cast<Node>() ?? const <Node>[];
    final excl = (filters?['exclude'] as List?)?.cast<Node>() ?? const <Node>[];

    final table = LayoutBuilder(
      builder: (context, box) {
        final cols = [
          for (final c in _cols)
            if (box.maxWidth >= c.minTable) c,
        ];
        Widget header() => Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: t.line)),
          ),
          child: Row(
            children: [
              for (final c in cols)
                _cell(
                  c,
                  InkWell(
                    onTap: c.sort == null
                        ? null
                        : () => setQ(
                            base.copyWith(
                              sort: c.sort,
                              desc: base.sort == c.sort ? !base.desc : false,
                            ),
                          ),
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            c.label,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: t.faint,
                              fontSize: DjType.small,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (base.sort == c.sort)
                          Icon(
                            base.desc
                                ? Icons.arrow_downward
                                : Icons.arrow_upward,
                            size: 13,
                            color: t.faint,
                          ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        );
        return Column(
          children: [
            header(),
            Expanded(
              child: (_total ?? 0) == 0
                  ? EmptyState(
                      icon: Icons.search_off,
                      title: error != null
                          ? "Couldn't search"
                          : 'No tracks match',
                      message: error ?? 'Unknown values (for example energy you haven\'t rated yet) never count as a match.',
                    )
                  : ListView.builder(
                      itemCount: _total,
                      itemExtent: 34,
                      itemBuilder: (c, i) {
                        final r = rowAt(s, eff, i);
                        if (r == null) return const SizedBox.shrink();
                        return _row(context, r, i, cols, notation, s, eff);
                      },
                    ),
            ),
          ],
        );
      },
    );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: PageFrame(
            title: title,
            subtitle: sub,
            scroll: false,
            actions: [
              if (crate != null)
                OutlinedButton.icon(
                  onPressed: () => showCrateDialog(context, ref, crate: crate),
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: const Text('Edit crate'),
                )
              else
                OutlinedButton.icon(
                  onPressed: () => addMusicFolders(ref),
                  icon: const Icon(Icons.create_new_folder_outlined, size: 18),
                  label: const Text('Add folder…'),
                ),
              FilledButton.icon(
                onPressed: scanning
                    ? null
                    : () => guard(() {
                        s.startScan();
                        ref.read(versionProvider.notifier).bump();
                      }, done: 'Read-only scan started.'),
                icon: const Icon(Icons.refresh, size: 18),
                label: Text(scanning ? 'Scanning…' : 'Scan'),
              ),
            ],
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _search,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Search your library (title, artist, etc.)',
                  ),
                  onChanged: (v) => setQ(base.copyWith(text: v)),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _facetButton(s, 'Genre', 'genre'),
                    _facetButton(s, 'Decade', 'decade'),
                    _optionsButton('Format', 'format', formatOptions),
                    _optionsButton('Quality', 'quality', qualityOptions),
                    OutlinedButton.icon(
                      onPressed: () async {
                        final r = await editRules(context, filters);
                        if (r != null) setQ(base.copyWith(filters: r));
                      },
                      icon: const Icon(Icons.filter_alt_outlined, size: 18),
                      label: Text(
                        'More filters${countRules(filters) > 0 ? ' (${countRules(filters)})' : ''}',
                      ),
                    ),
                    if (activeRules > 0)
                      TextButton(
                        onPressed: () => setState(() {
                          _quick.clear();
                          setQ(base.copyWith(clearFilters: true));
                        }),
                        child: const Text('Clear all'),
                      ),
                    if (activeRules > 0 && crate == null)
                      TextButton.icon(
                        onPressed: () => showCrateDialog(
                          context,
                          ref,
                          rules: cleanRuleSet(eff.filters),
                        ),
                        icon: const Icon(Icons.add, size: 16),
                        label: const Text('Save as smart crate'),
                      ),
                    Text(
                      _total == null ? '' : plural(_total!, 'track'),
                      style: TextStyle(color: t.faint),
                    ),
                  ],
                ),
                if (rules.isNotEmpty || excl.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (var i = 0; i < rules.length; i++)
                        InputChip(
                          label: Text(describeRule(rules[i])),
                          onDeleted: () => setQ(
                            base.copyWith(
                              filters: {
                                ...filters!,
                                'rules': [...rules]..removeAt(i),
                              },
                            ),
                          ),
                        ),
                      for (var i = 0; i < excl.length; i++)
                        InputChip(
                          label: Text('not ${describeRule(excl[i])}'),
                          onDeleted: () => setQ(
                            base.copyWith(
                              filters: {
                                ...filters!,
                                'exclude': [...excl]..removeAt(i),
                              },
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
                if (selected.length > 1 ||
                    (selected.length == 1 && !selected.contains(focus))) ...[
                  const SizedBox(height: 10),
                  _bulkBar(context, s, crate, crates),
                ],
                const SizedBox(height: 10),
                Expanded(
                  child: Card(clipBehavior: Clip.antiAlias, child: table),
                ),
              ],
            ),
          ),
        ),
        if (focus != null)
          SizedBox(
            width: 400,
            child: TrackDetailPane(
              key: ValueKey(focus),
              id: focus!,
              onClose: () => setState(() => focus = null),
              onWrite: (id) => showWriteDialog(context, ref, [id]),
            ),
          ),
      ],
    );
  }

  Widget _cell(_Col c, Widget child) => c.flex > 0
      ? Expanded(
          flex: c.flex,
          child: Padding(
            padding: const EdgeInsets.only(right: 8),
            child: child,
          ),
        )
      : SizedBox(
          width: c.width,
          child: Padding(
            padding: const EdgeInsets.only(right: 8),
            child: child,
          ),
        );

  Widget _row(
    BuildContext context,
    TrackRow r,
    int i,
    List<_Col> cols,
    String notation,
    AppSession s,
    LibraryQuery eff,
  ) {
    final t = DjTokens.of(context);
    final sel = selected.contains(r.id);
    Widget src(String? x) => x == 'analysis'
        ? Tooltip(
            message: 'Estimated by local analysis',
            child: Text(
              ' est',
              style: TextStyle(color: t.faint, fontSize: DjType.caption),
            ),
          )
        : x == 'you'
        ? Tooltip(
            message: 'Your catalogue value',
            child: Text(
              ' you',
              style: TextStyle(color: t.accent, fontSize: DjType.caption),
            ),
          )
        : const SizedBox.shrink();
    Text txt(String v, {Color? color}) => Text(
      v,
      overflow: TextOverflow.ellipsis,
      maxLines: 1,
      style: TextStyle(fontSize: DjType.body, color: color),
    );
    Widget content(_Col c) => switch (c.id) {
      'title' => Row(
        children: [
          Icon(
            r.mediaKind == 'video'
                ? Icons.movie_outlined
                : Icons.music_note_outlined,
            size: 15,
            color: t.faint,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: txt(
              r.title ?? r.fileName,
              color: r.title == null ? t.faint : null,
            ),
          ),
          if (r.version != null) ...[
            const SizedBox(width: 6),
            Pill(r.version!),
          ],
          if (r.cleanExplicit != null) ...[
            const SizedBox(width: 4),
            Pill(
              r.cleanExplicit == 'clean' ? 'C' : 'E',
              tooltip: r.cleanExplicit,
            ),
          ],
          if (r.status != 'ok') ...[
            const SizedBox(width: 4),
            Pill(statusLabel[r.status] ?? r.status, color: t.warn),
          ],
        ],
      ),
      'artist' => txt(fmtText(r.artist)),
      'genre' => txt(fmtText(r.genre), color: t.muted),
      'year' => txt(fmtText(r.year)),
      'bpm' => Row(children: [txt(fmtBpm(r.bpm)), src(r.bpmSource)]),
      'key' => Tooltip(
        message: keyHint(r.key) ?? '',
        child: Row(children: [txt(fmtKey(r.key, notation)), src(r.keySource)]),
      ),
      'energy' => EnergyMeter(
        value: r.energy,
        estimate: r.energySource == 'analysis',
      ),
      'rating' => Stars(value: r.rating),
      'time' => txt(fmtDuration(r.durationMs)),
      'format' => txt(
        (r.format ?? unknown).replaceAll('M4A (', '').replaceAll(')', ''),
      ),
      'bitrate' => switch (r.quality) {
        'video' => const Pill('Video'),
        'low_bitrate' => Pill(
          '${r.bitrateKbps} kbps',
          color: t.warn,
          tooltip: 'Lossy file under your low-bitrate threshold. Bitrate alone does not prove quality.',
        ),
        'lossless' => Pill('Lossless', color: t.ok),
        _ => txt(r.bitrateKbps == null ? unknown : '${r.bitrateKbps} kbps'),
      },
      _ => const SizedBox.shrink(),
    };
    return Material(
      color: sel
          ? t.accent.withValues(alpha: 0.13)
          : (i.isOdd ? t.panel2.withValues(alpha: 0.35) : Colors.transparent),
      child: InkWell(
        onTap: () {
          final keys = HardwareKeyboard.instance;
          setState(() {
            if (keys.isShiftPressed && _anchor != null) {
              final a = _anchor!.clamp(0, _total! - 1), b = i;
              for (var k = a < b ? a : b; k <= (a < b ? b : a); k++) {
                final x = rowAt(s, eff, k);
                if (x != null) selected.add(x.id);
              }
            } else if (keys.isControlPressed || keys.isMetaPressed) {
              selected.contains(r.id)
                  ? selected.remove(r.id)
                  : selected.add(r.id);
              _anchor = i;
            } else {
              selected
                ..clear()
                ..add(r.id);
              _anchor = i;
              focus = r.id;
            }
          });
        },
        onDoubleTap: () => setState(() => focus = r.id),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(children: [for (final c in cols) _cell(c, content(c))]),
        ),
      ),
    );
  }

  Widget _facetButton(AppSession s, String label, String facet) {
    final active = _quick[facet];
    return MenuAnchor(
      builder: (c, ctl, _) => FilterChip(
        label: Text(active == null ? label : '$label: ${active.label}'),
        selected: active != null,
        onSelected: (_) => ctl.isOpen ? ctl.close() : ctl.open(),
      ),
      menuChildren: [
        if (active != null)
          MenuItemButton(
            onPressed: () => setState(() => _quick[facet] = null),
            child: const Text('Any'),
          ),
        for (final (v, n) in s.library.facet(facet))
          MenuItemButton(
            onPressed: () => setState(
              () => _quick[facet] = QuickOption(
                facet == 'decade' ? '${v}s' : v,
                facet == 'decade'
                    ? cond('decade', 'eq', int.tryParse(v))
                    : cond(facet, 'equals', v),
              ),
            ),
            trailingIcon: Text('$n'),
            child: Text(facet == 'decade' ? '${v}s' : v),
          ),
      ],
    );
  }

  Widget _optionsButton(String label, String k, List<QuickOption> opts) {
    final active = _quick[k];
    return MenuAnchor(
      builder: (c, ctl, _) => FilterChip(
        label: Text(active == null ? label : '$label: ${active.label}'),
        selected: active != null,
        onSelected: (_) => ctl.isOpen ? ctl.close() : ctl.open(),
      ),
      menuChildren: [
        if (active != null)
          MenuItemButton(
            onPressed: () => setState(() => _quick[k] = null),
            child: const Text('Any'),
          ),
        for (final o in opts)
          MenuItemButton(
            onPressed: () => setState(() => _quick[k] = o),
            child: Text(o.label),
          ),
      ],
    );
  }

  Widget _bulkBar(
    BuildContext context,
    AppSession s,
    Crate? crate,
    List<Crate> crates,
  ) {
    final ids = selected.toList();
    void act(void Function() f, String msg) => guard(f, done: msg, bump: ref);
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              '${plural(ids.length, 'track')} selected',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            MenuAnchor(
              builder: (c, ctl, _) => OutlinedButton.icon(
                onPressed: ctl.open,
                icon: const Icon(Icons.inventory_2_outlined, size: 16),
                label: const Text('Add to crate'),
              ),
              menuChildren: [
                for (final c in crates.where(
                  (c) => c.id != crate?.id && c.kind != 'folder',
                ))
                  MenuItemButton(
                    onPressed: () => act(
                      () => s.crates.addTracks(c.id, ids),
                      'Added ${plural(ids.length, 'track')} to “${c.name}”.',
                    ),
                    child: Text(c.name),
                  ),
              ],
            ),
            MenuAnchor(
              builder: (c, ctl, _) => OutlinedButton(
                onPressed: ctl.open,
                child: const Text('Set energy'),
              ),
              menuChildren: [
                for (var n = 10; n >= 1; n--)
                  MenuItemButton(
                    onPressed: () => act(
                      () => s.library.updateUserFields(ids, {'energy': n}),
                      'Energy set to $n.',
                    ),
                    child: Text('$n'),
                  ),
                MenuItemButton(
                  onPressed: () => act(
                    () => s.library.updateUserFields(ids, {'energy': null}),
                    'Energy cleared.',
                  ),
                  child: const Text('Clear'),
                ),
              ],
            ),
            OutlinedButton(
              onPressed: () async {
                final tag = await askText(
                  context,
                  title: 'Add a tag',
                  label: 'Tag (e.g. Wedding, Peak time)',
                  ok: 'Add',
                );
                if (tag != null && tag.trim().isNotEmpty) {
                  act(
                    () => s.library.setTags(ids, add: [tag.trim()]),
                    'Tagged ${plural(ids.length, 'track')}.',
                  );
                }
              },
              child: const Text('Add tag'),
            ),
            if (crate != null)
              OutlinedButton(
                onPressed: () => act(() {
                  s.crates.removeTracks(crate.id, ids);
                  setState(selected.clear);
                }, 'Removed from “${crate.name}”. Files are untouched.'),
                child: const Text('Remove from crate'),
              ),
            OutlinedButton.icon(
              onPressed: () => showWriteDialog(context, ref, ids),
              icon: const Icon(Icons.edit_note, size: 18),
              label: const Text('Write tags to files…'),
            ),
            MenuAnchor(
              builder: (c, ctl, _) => OutlinedButton.icon(
                onPressed: ctl.open,
                icon: const Icon(Icons.ios_share, size: 16),
                label: const Text('Export'),
              ),
              menuChildren: [
                MenuItemButton(
                  onPressed: () => _export(s, ids, 'm3u8', crate),
                  child: const Text('Playlist (M3U8)…'),
                ),
                MenuItemButton(
                  onPressed: () => _export(s, ids, 'csv', crate),
                  child: const Text('Spreadsheet (CSV)…'),
                ),
              ],
            ),
            TextButton(
              onPressed: () => setState(selected.clear),
              child: const Text('Clear selection'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _export(
    AppSession s,
    List<int> ids,
    String ext,
    Crate? crate,
  ) async {
    final name = (crate?.name ?? 'DJ Assistant selection').replaceAll(
      RegExp(r'[\\/:*?"<>|]'),
      '_',
    );
    final loc = await getSaveLocation(
      suggestedName: '$name.$ext',
      acceptedTypeGroups: [
        XTypeGroup(label: ext.toUpperCase(), extensions: [ext]),
      ],
    );
    if (loc == null) return;
    await guard(
      () => ext == 'csv'
          ? s.exports.writeCsv(ids, loc.path)
          : s.exports.writeM3u(ids, loc.path),
      done: 'Exported to ${loc.path}. Your music files were not touched.',
    );
  }
}

/// Picks music folders and adds them as library roots, then scans.
Future<void> addMusicFolders(WidgetRef ref) async {
  final dirs = await getDirectoryPaths(confirmButtonText: 'Add folders');
  if (dirs.isEmpty) return;
  final s = ref.read(sessionProvider);
  var added = 0;
  for (final d in dirs.whereType<String>()) {
    try {
      s.roots.add(d);
      added++;
    } on Object catch (e) {
      toast('$e', error: true);
    }
  }
  if (added > 0) {
    s.startScan();
    toast('Added ${plural(added, 'folder')}. Read-only scan started.');
    ref.read(versionProvider.notifier).bump();
  }
}

/// An energy meter (1–10), editable when [onChanged] is set.
class EnergyMeter extends StatelessWidget {
  const EnergyMeter({
    super.key,
    this.value,
    this.estimate = false,
    this.onChanged,
    this.big = false,
  });
  final int? value;
  final bool estimate, big;
  final ValueChanged<int?>? onChanged;
  @override
  Widget build(BuildContext context) {
    final t = DjTokens.of(context);
    final v = value ?? 0;
    return Tooltip(
      message: value == null
          ? 'Not rated'
          : '$value/10${estimate ? ' (estimate)' : ''}',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 1; i <= 10; i++)
            GestureDetector(
              onTap: onChanged == null
                  ? null
                  : () => onChanged!(value == i ? null : i),
              child: Container(
                width: big ? 14 : 4,
                height: big ? 18 : 12,
                margin: const EdgeInsets.only(right: 1.5),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(1.5),
                  color: i <= v
                      ? Color.lerp(
                          t.accent,
                          t.warn,
                          i / 10,
                        )!.withValues(alpha: estimate ? 0.55 : 1)
                      : t.line,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class Stars extends StatelessWidget {
  const Stars({super.key, this.value, this.onChanged});
  final int? value;
  final ValueChanged<int?>? onChanged;
  @override
  Widget build(BuildContext context) {
    final t = DjTokens.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 1; i <= 5; i++)
          GestureDetector(
            onTap: onChanged == null
                ? null
                : () => onChanged!(value == i ? null : i),
            child: Icon(
              Icons.star_rounded,
              size: onChanged == null ? 13 : 20,
              color: (value ?? 0) >= i ? t.warn : t.line,
            ),
          ),
      ],
    );
  }
}

/// Export helpers re-exported for screens that only need them.
typedef Exports = ExportService;

/// Rows as JSON (used by the assistant panel previews).
List<Map<String, Object?>> rowsJson(List<TrackRow> rows) => [
  for (final r in rows) r.toJson(),
];
