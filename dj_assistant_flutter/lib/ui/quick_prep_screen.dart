import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/session.dart';
import '../assistant/quick_ai.dart';
import '../core/analysis_store.dart';
import '../core/gigpack.dart';
import '../core/library.dart';
import '../core/library_edit.dart';
import '../online/http_online.dart' show appVersion;
import '../quick/genres.dart';
import '../quick/names.dart';
import '../quick/setlist.dart';
import 'format.dart';
import 'player.dart';
import 'state.dart';
import 'theme.dart';
import 'widgets.dart';

/// One track of the batch with Quick Prep's proposals (1.x quick/model.ts).
class QTrack extends SetTrack {
  QTrack(
    this.row,
    this.name,
    this.edited,
    String genre,
    this.genreSource,
    this.messy,
    this.role,
  ) : super(
        '${row.id}',
        row.bpm ?? 0,
        row.key ?? '',
        (row.energy ?? 5).toDouble(),
        genre,
      );
  final TrackRow row;
  final CleanName name;
  final bool edited, messy;
  final String genreSource, role;
  int get rid => row.id;
}

CleanName autoName(TrackRow r) {
  final n = cleanName(r.fileName, artist: r.artist, title: r.title);
  return n.mix.isEmpty && r.version != null ? n.copyWith(mix: r.version) : n;
}

/// Quick Prep state, kept while visiting other screens.
class QState {
  String screen = 'start'; // start | analysing | paths | clean | playlist | folders | genres
  String label = '';
  int? rootId, crateId;
  List<int> ids = [];
  final rows = <int, TrackRow>{};
  final names = <int, (CleanName, bool)>{}; // proposal, edited by you
  final aiGenre = <int, String>{};
  String step = 'idle', message = '';
  int done = 0, total = 0;
  String format = 'artist-title';
  bool useClean = true, families = false, numbered = true;
  String playlistName = 'My Set', note = '';
  List<int> order = [];
  List<(String, List<String>)> mains = [
    ('Friday Night', ['Warm Up', 'Groove', 'Peak Time']),
  ];
  final bins = <int, int>{}; // track → bin index

  List<(String, String)> get flatBins => [
    for (final (m, subs) in mains)
      if (subs.isEmpty) (m, '') else for (final s in subs) (m, s),
  ];

  List<QTrack> get tracks {
    final base = [for (final id in ids) ?rows[id]]
        .where((r) => r.status == 'ok')
        .toList();
    final roles = assignRoles([
      for (final r in base)
        SetTrack('${r.id}', r.bpm ?? 0, '', (r.energy ?? 5).toDouble()),
    ]);
    return [
      for (final r in base)
        () {
          final p = names[r.id];
          final name = p?.$1 ?? autoName(r);
          final ai = aiGenre[r.id];
          final genre = ai ?? r.genre ?? guessGenre(r.bpm ?? 0, r.energy ?? 5);
          final inCatalogue =
              (name.title.isEmpty ? null : name.title) == r.title &&
              (name.artist.isEmpty ? null : name.artist) == r.artist &&
              (name.mix.isEmpty ? null : name.mix) == r.version;
          return QTrack(
            r,
            name,
            p?.$2 ?? false,
            genre,
            ai != null ? 'ai' : (r.genre != null ? 'catalogue' : 'guess'),
            needsCleanup(r.fileName, name, format) && !inCatalogue,
            roles['${r.id}'] ?? 'Groove',
          );
        }(),
    ];
  }
}

class QuickNotifier extends Notifier<QState> {
  @override
  QState build() {
    ref.watch(sessionProvider); // a new account starts over
    return QState();
  }

  void changed() => state = state; // the state object is edited in place
  void reset() => state = QState()..format = state.format;
}

final quickProvider = NotifierProvider<QuickNotifier, QState>(
  QuickNotifier.new,
);

class QuickPrepScreen extends ConsumerStatefulWidget {
  const QuickPrepScreen({super.key});
  @override
  ConsumerState<QuickPrepScreen> createState() => _QuickPrepScreenState();
}

class _QuickPrepScreenState extends ConsumerState<QuickPrepScreen> {
  QState get st => ref.read(quickProvider);
  void _changed() {
    ref.read(quickProvider.notifier).changed();
    setState(() {});
  }

  void _reload(AppSession s) {
    final q = TrackQuery(
      rootId: st.rootId,
      extraWhere: st.crateId == null ? null : s.crates.membership(st.crateId!),
      sort: 'artist',
      limit: 20000,
    );
    for (final r in s.library.search(q).rows) {
      if (st.ids.contains(r.id)) st.rows[r.id] = r;
    }
  }

  /// Scan (for a new folder) → analyse what's missing → ready.
  Future<void> _prepare(
    String label, {
    int? rootId,
    int? crateId,
    bool scan = false,
  }) async {
    final s = ref.read(sessionProvider);
    ref.read(quickProvider.notifier).reset();
    st
      ..screen = 'analysing'
      ..label = label
      ..rootId = rootId
      ..crateId = crateId
      ..step = 'scanning';
    _changed();
    try {
      if (scan) await s.scan.start(rootIds: [rootId!]);
      final q = TrackQuery(
        rootId: rootId,
        extraWhere: crateId == null ? null : s.crates.membership(crateId),
        sort: 'artist',
        limit: 20000,
      );
      final rows = s.library
          .search(q)
          .rows
          .where((r) => r.status == 'ok' && r.mediaKind == 'audio')
          .toList();
      st.ids = [for (final r in rows) r.id];
      for (final r in rows) {
        st.rows[r.id] = r;
      }
      st
        ..order = List.of(st.ids)
        ..playlistName = label.isEmpty ? 'My Set' : label;
      if (rows.isEmpty) {
        st
          ..step = 'failed'
          ..message = 'No playable audio found there.';
        return _changed();
      }
      final todo = [
        for (final r in rows)
          if (r.analysis == null) r.id,
      ];
      if (todo.isNotEmpty) {
        st
          ..step = 'analysing'
          ..total = todo.length;
        _changed();
        final run = s.jobs.start('analysis', analysisJob(s.dbPath, only: todo));
        final timer = Timer.periodic(const Duration(milliseconds: 600), (_) {
          final j = s.jobs.status('analysis');
          st.done = j.done;
          _reload(s);
          if (mounted) _changed();
        });
        try {
          await run;
        } finally {
          timer.cancel();
        }
      }
      _reload(s);
      st
        ..step = 'ready'
        ..done = st.ids.length
        ..total = st.ids.length;
      ref.read(versionProvider.notifier).bump();
    } on Object catch (e) {
      st
        ..step = 'failed'
        ..message = '$e';
    }
    if (mounted) _changed();
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(sessionProvider);
    ref.watch(quickProvider);
    final t = DjTokens.of(context);
    const titles = {
      'clean': 'Clean names',
      'playlist': 'Build a playlist',
      'folders': 'Organise folders',
      'genres': 'Split by genre',
    };
    final tracks = st.tracks;
    final inPath = titles.containsKey(st.screen);
    return PageFrame(
      title: 'Quick Prep${inPath ? ' · ${titles[st.screen]}' : ''}',
      subtitle: st.screen == 'start'
          ? 'Drop in a folder and get it gig-ready: clean names, a playlist, folders or genres — then export a verified copy.'
          : '${st.label} · ${plural(tracks.length, 'track')}',
      actions: [
        if (inPath)
          OutlinedButton.icon(
            onPressed: () => setState(() => st.screen = 'paths'),
            icon: const Icon(Icons.arrow_back, size: 18),
            label: const Text('All paths'),
          ),
        if (st.screen != 'start')
          TextButton(
            onPressed: () {
              ref.read(quickProvider.notifier).reset();
              setState(() {});
            },
            child: const Text('Start over'),
          ),
      ],
      child: switch (st.screen) {
        'start' => _start(context, s),
        'analysing' => _analysing(context, t),
        'paths' => _paths(context, tracks),
        'clean' => _clean(context, s, tracks),
        'playlist' => _playlist(context, s, tracks),
        'folders' => _folders(context, tracks),
        _ => _genres(context, s, tracks),
      },
    );
  }

  Widget _start(BuildContext context, AppSession s) {
    final roots = ref.watch(rootsProvider);
    final crates = ref
        .watch(cratesProvider)
        .where((c) => c.kind != 'folder')
        .toList();
    const features = [
      (
        Icons.auto_fix_high,
        'Clean names',
        'Strips “[FREE DL]”, “320kbps”, track numbers and underscores, and fixes capitals.',
      ),
      (
        Icons.queue_music,
        'Build a playlist',
        'Warm-up to peak with harmonic mixing, by BPM, or from what you type.',
      ),
      (
        Icons.folder_copy_outlined,
        'Organise folders',
        'Sort into gig folders while you listen.',
      ),
      (
        Icons.layers_outlined,
        'Split by genre',
        'Group by genre or by family, ready for your DJ software.',
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Panel(
          child: Column(
            children: [
              Icon(
                Icons.create_new_folder_outlined,
                size: 34,
                color: DjTokens.of(context).accent,
              ),
              const SizedBox(height: 8),
              Text(
                'Add a folder of tracks',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 4),
              const Text(
                "It's added to your library (read-only) and analysed on this computer — BPM, key, energy. Your files are never changed, moved or renamed.",
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: () async {
                  final d = await getDirectoryPath(
                    confirmButtonText: 'Use this folder',
                  );
                  if (d == null) return;
                  final known = roots
                      .where(
                        (r) =>
                            r.path.toLowerCase().replaceAll(
                              RegExp(r'[\\/]+$'),
                              '',
                            ) ==
                            d.toLowerCase().replaceAll(RegExp(r'[\\/]+$'), ''),
                      )
                      .firstOrNull;
                  final root = known ?? await guard(() => s.roots.add(d));
                  if (root == null) return;
                  ref.read(versionProvider.notifier).bump();
                  await _prepare(
                    d.split(RegExp(r'[\\/]')).where((x) => x.isNotEmpty).last,
                    rootId: root.id,
                    scan: true,
                  );
                },
                icon: const Icon(Icons.folder_open),
                label: const Text('Choose a folder'),
              ),
            ],
          ),
        ),
        gap,
        Wrap(
          spacing: 16,
          runSpacing: 16,
          children: [
            if (roots.isNotEmpty)
              SizedBox(
                width: 380,
                child: Panel(
                  title: 'Or a music folder already in your library',
                  child: Column(
                    children: [
                      for (final r in roots)
                        ListTile(
                          dense: true,
                          title: Text(r.label ?? r.path),
                          onTap: () =>
                              _prepare(r.label ?? r.path, rootId: r.id),
                        ),
                    ],
                  ),
                ),
              ),
            if (crates.isNotEmpty)
              SizedBox(
                width: 380,
                child: Panel(
                  title: 'Or a crate',
                  child: Column(
                    children: [
                      for (final c in crates)
                        ListTile(
                          dense: true,
                          title: Text(c.name),
                          trailing: Text(plural(c.trackCount, 'track')),
                          onTap: () => _prepare(c.name, crateId: c.id),
                        ),
                    ],
                  ),
                ),
              ),
          ],
        ),
        gap,
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final (icon, title, text) in features)
              SizedBox(
                width: 240,
                child: Panel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(icon),
                      const SizedBox(height: 6),
                      Text(
                        title,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        text,
                        style: const TextStyle(fontSize: DjType.small),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _analysing(BuildContext context, DjTokens t) => Panel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ProgressLine(
          label: switch (st.step) {
            'scanning' => 'Reading the folder…',
            'analysing' => 'Analysing BPM, key and energy…',
            'ready' => 'Ready',
            'failed' => "Couldn't prepare these tracks",
            _ => '',
          },
          done: st.done,
          total: st.total,
          message: st.step == 'failed' ? st.message : null,
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            TextButton(
              onPressed: () => setState(() => st.screen = 'start'),
              child: const Text('Back'),
            ),
            const Spacer(),
            FilledButton(
              onPressed: st.step == 'ready'
                  ? () => setState(() => st.screen = 'paths')
                  : null,
              child: const Text('Continue'),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _paths(BuildContext context, List<QTrack> tracks) {
    final messy = tracks.where((x) => x.messy).length;
    final cards = [
      (
        'clean',
        Icons.auto_fix_high,
        'Clean names',
        '$messy of ${tracks.length} names need tidying.',
      ),
      (
        'playlist',
        Icons.queue_music,
        'Build a playlist',
        'Order the tracks for a set.',
      ),
      (
        'folders',
        Icons.folder_copy_outlined,
        'Organise folders',
        'Sort into gig folders.',
      ),
      (
        'genres',
        Icons.layers_outlined,
        'Split by genre',
        'A folder per genre or family.',
      ),
    ];
    return Wrap(
      spacing: 14,
      runSpacing: 14,
      children: [
        for (final (id, icon, title, text) in cards)
          SizedBox(
            width: 260,
            child: Card(
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => setState(() => st.screen = id),
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(icon, size: 28, color: DjTokens.of(context).accent),
                      const SizedBox(height: 10),
                      Text(
                        title,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: DjType.title,
                        ),
                      ),
                      Text(
                        text,
                        style: TextStyle(color: DjTokens.of(context).faint),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _formatToggle() => SegmentedButton<String>(
    segments: const [
      ButtonSegment(value: 'artist-title', label: Text('Artist - Title')),
      ButtonSegment(value: 'title-artist', label: Text('Title - Artist')),
    ],
    selected: {st.format},
    onSelectionChanged: (v) {
      st.format = v.first;
      _changed();
    },
  );

  Widget _clean(BuildContext context, AppSession s, List<QTrack> tracks) {
    final t = DjTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _formatToggle(),
            OutlinedButton.icon(
              onPressed: () async {
                final batch = tracks.where((x) => !x.edited).take(25).toList();
                final r = await guard(
                  () => AiHelpers(s).tidy([
                    for (final x in batch) (x.rid, x.name.toJson()),
                  ], allGenres),
                );
                if (r == null) return;
                for (final x in r) {
                  st.names[x.id] = (CleanName(x.artist, x.title, x.mix), false);
                  if (x.genre != null) st.aiGenre[x.id] = x.genre!;
                }
                _changed();
                toast(
                  'The AI suggested ${r.length} name(s). Your own edits are kept.',
                );
              },
              icon: const Icon(Icons.auto_awesome, size: 18),
              label: const Text('Sharpen with AI'),
            ),
            FilledButton(
              onPressed: () => guard(() {
                final n = _saveNames(s, tracks);
                toast(
                  'Saved $n clean name(s) to your catalogue. Files keep their names until you export.',
                );
              }, bump: ref),
              child: const Text('Save names to catalogue'),
            ),
            OutlinedButton(
              onPressed: () => _export(context, s, tracks, const CleanLayout()),
              child: const Text('Export a clean copy…'),
            ),
          ],
        ),
        const SizedBox(height: 10),
        for (final x in tracks)
          Card(
            margin: const EdgeInsets.only(bottom: 6),
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  SizedBox(
                    width: 200,
                    child: PreviewPlayer(
                      path: x.row.path,
                      durationMs: x.row.durationMs,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          x.row.fileName,
                          style: TextStyle(
                            color: t.faint,
                            fontSize: DjType.small,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          formatName(x.name, st.format),
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: x.messy ? t.accent : null,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Edit',
                    onPressed: () => _editName(context, x),
                    icon: const Icon(Icons.edit_outlined, size: 18),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  int _saveNames(AppSession s, List<QTrack> tracks) {
    var n = 0;
    for (final x in tracks.where((x) => x.messy)) {
      s.library.updateUserFields(
        [x.rid],
        {
          'artist': x.name.artist.isEmpty ? null : x.name.artist,
          'title': x.name.title.isEmpty ? null : x.name.title,
          'version_label': x.name.mix.isEmpty ? null : x.name.mix,
        },
      );
      n++;
    }
    _reload(s);
    return n;
  }

  Future<void> _editName(BuildContext context, QTrack x) async {
    final a = TextEditingController(text: x.name.artist),
        ti = TextEditingController(text: x.name.title),
        m = TextEditingController(text: x.name.mix);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Clean name'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: a,
                decoration: const InputDecoration(labelText: 'Artist'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: ti,
                decoration: const InputDecoration(labelText: 'Title'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: m,
                decoration: const InputDecoration(labelText: 'Mix / version'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Use'),
          ),
        ],
      ),
    );
    if (ok == true) {
      st.names[x.rid] = (
        CleanName(a.text.trim(), ti.text.trim(), m.text.trim()),
        true,
      );
      _changed();
    }
  }

  Widget _playlist(BuildContext context, AppSession s, List<QTrack> tracks) {
    final t = DjTokens.of(context);
    final byId = {for (final x in tracks) x.rid: x};
    final ordered = [for (final id in st.order) ?byId[id]];
    final request = TextEditingController();
    final notation = '${ref.watch(settingsProvider)['key_notation']}';
    void sortBy(String cmd) {
      st.order = [for (final x in applySort(cmd, ordered)) x.rid];
      _changed();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (cmd, label) in [
              ('warmup-peak', 'Warm-up → peak'),
              ('ascending-bpm', 'BPM up'),
              ('descending-bpm', 'BPM down'),
              ('key', 'Harmonic (key)'),
              ('genre', 'By genre'),
              ('energy-up', 'Energy up'),
            ])
              OutlinedButton(onPressed: () => sortBy(cmd), child: Text(label)),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: request,
                decoration: const InputDecoration(
                  hintText: 'Or say how: “start deep, end on the big vocals”',
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonal(
              onPressed: () async {
                final cmd = parseSortRequest(request.text);
                if (cmd != null) return sortBy(cmd);
                final r = await guard(
                  () => AiHelpers(s).order(st.order, request.text),
                );
                if (r == null) return;
                st
                  ..order = r.$1
                  ..note = r.$2;
                _changed();
              },
              child: const Text('Order'),
            ),
          ],
        ),
        if (st.note.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(st.note, style: TextStyle(color: t.muted)),
          ),
        const SizedBox(height: 8),
        Text(
          'Smoothness: ${setCost(ordered).toStringAsFixed(1)} (lower mixes better)',
          style: TextStyle(color: t.faint),
        ),
        SizedBox(
          height: 420,
          child: ReorderableListView(
            buildDefaultDragHandles: true,
            onReorderItem: (a, b) {
              final id = st.order.removeAt(a);
              st.order.insert(b, id);
              _changed();
            },
            children: [
              for (final (i, x) in ordered.indexed)
                ListTile(
                  key: ValueKey(x.rid),
                  dense: true,
                  leading: Text('${i + 1}'),
                  title: Text(formatName(x.name, st.format)),
                  subtitle: Text(
                    '${fmtBpm(x.bpm)} BPM · ${fmtKey(x.camelot, notation)} · energy ${x.energy.round()} · ${x.genre}',
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: 260,
              child: TextFormField(
                initialValue: st.playlistName,
                decoration: const InputDecoration(labelText: 'Playlist name'),
                onChanged: (v) => st.playlistName = v,
              ),
            ),
            FilterChip(
              label: const Text('Number the files'),
              selected: st.numbered,
              onSelected: (v) => setState(() => st.numbered = v),
            ),
            FilterChip(
              label: const Text('Use clean names'),
              selected: st.useClean,
              onSelected: (v) => setState(() => st.useClean = v),
            ),
            FilledButton(
              onPressed: () => _export(
                context,
                s,
                tracks,
                PlaylistLayout(
                  st.playlistName,
                  st.order,
                  numbered: st.numbered,
                ),
              ),
              child: const Text('Export…'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _folders(BuildContext context, List<QTrack> tracks) {
    final s = ref.read(sessionProvider);
    final bins = st.flatBins;
    String label((String, String) b) =>
        b.$2.isEmpty ? b.$1 : '${b.$1} / ${b.$2}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton(
              onPressed: () async {
                final v = await askText(
                  context,
                  title: 'Folders',
                  label: 'Main folder: Sub, Sub; Another: Sub',
                  initial: [
                    for (final (m, subs) in st.mains) '$m: ${subs.join(', ')}',
                  ].join('; '),
                  ok: 'Use',
                );
                if (v == null) return;
                st.mains = [
                  for (final part in v.split(';'))
                    if (part.trim().isNotEmpty)
                      (
                        part.split(':').first.trim(),
                        [
                          for (final x
                              in (part.contains(':') ? part.split(':')[1] : '')
                                  .split(','))
                            if (x.trim().isNotEmpty) x.trim(),
                        ],
                      ),
                ];
                st.bins.clear();
                _changed();
              },
              child: const Text('Set up folders…'),
            ),
            OutlinedButton(
              onPressed: () {
                for (final x in tracks) {
                  final i = bins.indexWhere((b) => b.$2 == x.role);
                  if (i >= 0) st.bins[x.rid] = i;
                }
                _changed();
              },
              child: const Text('Sort by energy role'),
            ),
            FilledButton(
              onPressed: () => _export(
                context,
                s,
                tracks,
                FoldersLayout([
                  for (var i = 0; i < bins.length; i++)
                    (
                      bins[i].$1,
                      bins[i].$2,
                      [
                        for (final e in st.bins.entries)
                          if (e.value == i) e.key,
                      ],
                    ),
                ]),
              ),
              child: const Text('Export…'),
            ),
          ],
        ),
        const SizedBox(height: 10),
        for (final x in tracks)
          Card(
            margin: const EdgeInsets.only(bottom: 6),
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  SizedBox(
                    width: 200,
                    child: PreviewPlayer(
                      path: x.row.path,
                      durationMs: x.row.durationMs,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(formatName(x.name, st.format))),
                  DropdownButton<int?>(
                    isExpanded: true,
                    style: Theme.of(context).textTheme.bodyMedium,
                    value: st.bins[x.rid],
                    hint: const Text('Unsorted'),
                    items: [
                      const DropdownMenuItem(
                        value: null,
                        child: Text('Unsorted'),
                      ),
                      for (var i = 0; i < bins.length; i++)
                        DropdownMenuItem(value: i, child: Text(label(bins[i]))),
                    ],
                    onChanged: (v) {
                      v == null ? st.bins.remove(x.rid) : st.bins[x.rid] = v;
                      _changed();
                    },
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _genres(BuildContext context, AppSession s, List<QTrack> tracks) {
    final t = DjTokens.of(context);
    final groups = <String, int>{};
    for (final x in tracks) {
      final g = st.families ? genreFamily(x.genre) : x.genre;
      groups[g] = (groups[g] ?? 0) + 1;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('By genre')),
                ButtonSegment(value: true, label: Text('Group into families')),
              ],
              selected: {st.families},
              onSelectionChanged: (v) {
                st.families = v.first;
                _changed();
              },
            ),
            OutlinedButton(
              onPressed: () => guard(() {
                var n = 0;
                for (final x in tracks.where(
                  (x) => x.genreSource != 'catalogue',
                )) {
                  s.library.updateUserFields([x.rid], {'genre': x.genre});
                  n++;
                }
                _reload(s);
                toast('Saved $n genre(s) to your catalogue.');
              }, bump: ref),
              child: const Text('Save genres to catalogue'),
            ),
            FilledButton(
              onPressed: () => _export(
                context,
                s,
                tracks,
                GenresLayout(families: st.families),
              ),
              child: const Text('Export…'),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final e in groups.entries)
              Chip(label: Text('${e.key} (${e.value})')),
          ],
        ),
        const SizedBox(height: 10),
        for (final x in tracks)
          ListTile(
            dense: true,
            title: Text(formatName(x.name, st.format)),
            subtitle: Text('${fmtBpm(x.bpm)} BPM · energy ${x.energy.round()}'),
            trailing: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 6,
              children: [
                if (x.genreSource == 'guess')
                  Pill(
                    'guess',
                    color: t.warn,
                    tooltip: 'Guessed from tempo and energy — check it',
                  ),
                if (x.genreSource == 'ai') const Pill('AI'),
                DropdownButton<String>(
                  isExpanded: true,
                  style: Theme.of(context).textTheme.bodyMedium,
                  value: allGenres.contains(x.genre) ? x.genre : null,
                  hint: Text(x.genre),
                  items: [
                    for (final g in allGenres)
                      DropdownMenuItem(value: g, child: Text(g)),
                  ],
                  onChanged: (g) {
                    st.aiGenre[x.rid] = g!;
                    _changed();
                  },
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// Verified copy of the batch with the chosen layout (1.x QuickExport).
  Future<void> _export(
    BuildContext context,
    AppSession s,
    List<QTrack> tracks,
    Layout layout,
  ) async {
    final dest = await getDirectoryPath(confirmButtonText: 'Export here');
    if (dest == null || !context.mounted) return;
    var zip = false, writeTags = false;
    final go = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: const Text('Export a verified copy'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Into a new folder in $dest. Your originals are only read; nothing is overwritten.',
                ),
                SwitchListTile(
                  value: zip,
                  onChanged: (v) => set(() => zip = v),
                  title: const Text('As one ZIP file'),
                ),
                SwitchListTile(
                  value: writeTags,
                  onChanged: (v) => set(() => writeTags = v),
                  title: const Text('Write clean tags into the copies'),
                  subtitle: const Text(
                    'Only the copies change; your library files stay as they are.',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Export'),
            ),
          ],
        ),
      ),
    );
    if (go != true) return;
    final lt = [
      for (final x in tracks)
        LayoutTrack(
          x.rid,
          st.useClean
              ? x.name
              : CleanName(
                  '',
                  x.row.fileName.replaceFirst(RegExp(r'\.[^.]+$'), ''),
                  '',
                ),
          x.genre,
          x.bpm,
        ),
    ];
    final pl = buildLayout(lt, layout, st.format);
    final plan = await guard(
      () => s.gigPack.preview(
        [for (final i in pl.items) i.$1],
        dest,
        st.label.isEmpty ? 'Quick Prep' : st.label,
        opts: PackOptions(
          items: [
            for (final (id, folder, name) in pl.items)
              PackItem(id, folder: folder, name: name),
          ],
          playlists: [
            for (final (name, path, ids) in pl.playlists)
              PackPlaylist(name, path, ids),
          ],
          zip: zip,
          writeTags: writeTags,
        ),
      ),
    );
    if (plan == null) return;
    if (!plan.fits) {
      return toast('Not enough space on that drive.', error: true);
    }
    final path = s.dbPath;
    s.jobs
        .start('gigpack', gigPackJob(path, plan, appVersion: appVersion))
        .ignore();
    toast(
      'Copying and verifying ${plural(plan.files.length, 'file')} into ${plan.packDir}…',
    );
    ref.read(versionProvider.notifier).bump();
  }
}
