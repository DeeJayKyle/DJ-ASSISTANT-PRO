import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'catalogue.dart';
import 'jobs.dart';
import 'keys.dart';
import 'library.dart';
import 'library_edit.dart';
import 'suggestions.dart';
import 'tags.dart';
import 'text.dart';

/// External taggers (MusicBrainz Picard, OneTagger, Mp3tag, beets) working
/// hand in hand with DJ Assistant's own analysis.
///
/// The rule: **no tool ever touches the DJ's music.** Each tool gets its own
/// copies of the chosen tracks in a workspace in the app's data folder. The
/// automatic tools (OneTagger, beets) run on their copies in the background;
/// the interactive ones (Picard, Mp3tag) open on theirs and the DJ saves there.
/// Then DJ Assistant reads every copy back, compares it with the original tags,
/// and merges what the tools found into review-first Suggestions: values that
/// several tools agree on score higher, and disagreements are spelled out in
/// the evidence. Accepting a suggestion changes the catalogue only.

enum TaggerMode { automatic, interactive }

/// One external tool, what it is good at and how far its findings are trusted
/// per field (the starting confidence of a suggestion it alone makes).
class TaggerDef {
  const TaggerDef({
    required this.id,
    required this.name,
    required this.mode,
    required this.strength,
    required this.sends,
    required this.site,
    required this.exeNames,
    required this.windowsPaths,
    required this.trust,
  });
  final String id, name, strength, sends, site;
  final TaggerMode mode;

  /// File names to look for on PATH (".exe" is added on Windows).
  final List<String> exeNames;

  /// Usual install locations on Windows (%VAR% is expanded).
  final List<String> windowsPaths;
  final Map<String, double> trust;
}

const taggerDefs = <TaggerDef>[
  TaggerDef(
    id: 'onetagger',
    name: 'OneTagger',
    mode: TaggerMode.automatic,
    strength:
        'DJ shops: genre, style, label, BPM, key and release date from '
        'Beatport, Traxsource, Juno Download and MusicBrainz.',
    sends:
        'OneTagger (not DJ Assistant) sends each copy\'s artist, title and '
        'duration to the platforms you choose.',
    site: 'https://onetagger.github.io',
    exeNames: ['onetagger-cli'],
    windowsPaths: [
      r'%ProgramFiles%\OneTagger\onetagger-cli.exe',
      r'%LOCALAPPDATA%\OneTagger\onetagger-cli.exe',
      r'%USERPROFILE%\Downloads\onetagger-cli.exe',
    ],
    trust: {
      'genre': 0.80,
      'record_label': 0.85,
      'bpm': 0.80,
      'key': 0.80,
      'year': 0.75,
      'album': 0.70,
      'title': 0.60,
      'artist': 0.60,
    },
  ),
  TaggerDef(
    id: 'beets',
    name: 'beets',
    mode: TaggerMode.automatic,
    strength:
        'MusicBrainz releases: correct title, artist, album, year, original '
        'year and label (genre with the lastgenre plugin).',
    sends:
        'beets (not DJ Assistant) sends each copy\'s tags to MusicBrainz, and '
        'to any plugin services you list.',
    site: 'https://beets.io',
    exeNames: ['beet'],
    windowsPaths: [
      r'%APPDATA%\Python\Scripts\beet.exe',
      r'%LOCALAPPDATA%\Programs\Python\Python313\Scripts\beet.exe',
      r'%LOCALAPPDATA%\Programs\Python\Python312\Scripts\beet.exe',
    ],
    trust: {
      'title': 0.80,
      'artist': 0.80,
      'album': 0.85,
      'year': 0.85,
      'original_year': 0.85,
      'record_label': 0.75,
      'genre': 0.60,
    },
  ),
  TaggerDef(
    id: 'picard',
    name: 'MusicBrainz Picard',
    mode: TaggerMode.interactive,
    strength:
        'Acoustic fingerprints (AcoustID) and MusicBrainz: finds the exact '
        'release even for badly tagged files. You check and save in Picard.',
    sends:
        'Picard (not DJ Assistant) sends fingerprints and tags to AcoustID and '
        'MusicBrainz when you look tracks up.',
    site: 'https://picard.musicbrainz.org',
    exeNames: ['picard'],
    windowsPaths: [
      r'%ProgramFiles%\MusicBrainz Picard\picard.exe',
      r'%ProgramFiles(x86)%\MusicBrainz Picard\picard.exe',
      r'%LOCALAPPDATA%\Programs\MusicBrainz Picard\picard.exe',
    ],
    trust: {
      'title': 0.85,
      'artist': 0.85,
      'album': 0.90,
      'year': 0.85,
      'original_year': 0.85,
      'record_label': 0.80,
      'genre': 0.60,
    },
  ),
  TaggerDef(
    id: 'mp3tag',
    name: 'Mp3tag',
    mode: TaggerMode.interactive,
    strength:
        'Hands-on editing: tag sources (Discogs, MusicBrainz…), actions and '
        'batch fixes, checked by you before saving.',
    sends:
        'Mp3tag (not DJ Assistant) only goes online when you use one of its '
        'tag sources.',
    site: 'https://www.mp3tag.de/en/',
    exeNames: ['Mp3tag'],
    windowsPaths: [
      r'%ProgramFiles%\Mp3tag\Mp3tag.exe',
      r'%ProgramFiles(x86)%\Mp3tag\Mp3tag.exe',
    ],
    trust: {
      'title': 0.90,
      'artist': 0.90,
      'album': 0.90,
      'genre': 0.90,
      'year': 0.90,
      'original_year': 0.90,
      'record_label': 0.90,
      'bpm': 0.90,
      'key': 0.90,
    },
  ),
];

TaggerDef? taggerById(String id) =>
    taggerDefs.where((t) => t.id == id).firstOrNull;

/// The suggestion fields taggers can fill, read from a file's tags.
const taggerFields = [
  'title',
  'artist',
  'album',
  'genre',
  'year',
  'original_year',
  'bpm',
  'key',
  'record_label',
];

/// OneTagger's default platforms (no account needed) and tags.
const defaultOneTaggerPlatforms =
    'beatport,traxsource,junodownload,musicbrainz';
const oneTaggerTags =
    'title,artist,album,genre,style,key,bpm,label,releaseDate';

class TaggerException implements Exception {
  TaggerException(this.message);
  final String message;
  @override
  String toString() => message;
}

Never _no(String m) => throw TaggerException(m);

/// A file's tags as comparable text, per [taggerFields]. Keys become Camelot
/// codes, BPMs one decimal, so "Am" and "8A" or "128" and "128.0" agree.
Map<String, String> tagValues(AudioMeta m) {
  String? s(String? v) => (v == null || v.trim().isEmpty) ? null : v.trim();
  final bpm = m.bpm;
  return {
    'title': ?s(m.title),
    'artist': ?s(m.artist),
    'album': ?s(m.album),
    'genre': ?s(m.genre),
    if (m.year != null) 'year': '${m.year}',
    if (m.originalYear != null && m.originalYear != m.year)
      'original_year': '${m.originalYear}',
    if (bpm != null && bpm > 0 && bpm < 1000)
      'bpm': rustNumber((bpm * 10).round() / 10),
    if (s(m.key) case final k?) 'key': normalizeKey(k) ?? k,
    'record_label': ?s(m.label),
  };
}

/// How two values compare for agreement: the same fact written the way
/// different tools write it compares equal. Case, accents and spacing never
/// matter; then per field:
///  * title: "(Original Mix)" is no version, brackets [ ] equal ( ), and a
///    featured artist in the title is ignored;
///  * artist: "feat.", "ft.", "featuring", "&", "and", "x", "," all join
///    names, in any order;
///  * genre: "Hip-Hop" = "Hip Hop" = "HipHop", "R&B" = "RnB";
///  * label: "Records", "Recordings", "Music", "Ltd" endings are dropped;
///  * year: the first four digits ("2019-05-03" = "2019");
///  * BPM to the half beat; keys as Camelot codes.
String agreeKey(String field, String v) {
  String words(String x) =>
      x.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).join(' ');
  final f = fold(v);
  switch (field) {
    case 'bpm':
      return rustNumber(((double.tryParse(v) ?? 0) * 2).round() / 2);
    case 'key':
      return normalizeKey(v) ?? f;
    case 'year' || 'original_year':
      return RegExp(r'\d{4}').firstMatch(v)?[0] ?? f;
    case 'title':
      var t = f.replaceAll('[', '(').replaceAll(']', ')');
      t = t.replaceAll(RegExp(r'\(\s*(feat\.?|ft\.?|featuring)\s[^)]*\)'), '');
      t = t.replaceAll(
        RegExp(r'\s(feat\.?|ft\.?|featuring)\s.*?(?=\(|$)'),
        ' ',
      );
      t = t.replaceAll(RegExp(r'\(\s*original( mix)?\s*\)'), '');
      return words(t);
    case 'artist':
      final names =
          f
              .split(
                RegExp(
                  r'\s+(?:feat\.?|ft\.?|featuring|&|and|x|vs\.?)\s+|\s*,\s*',
                ),
              )
              .map(words)
              .where((n) => n.isNotEmpty)
              .toSet()
              .toList()
            ..sort();
      return names.join(' + ');
    case 'genre':
      return f.replaceAll('&', 'n').replaceAll(RegExp(r'[^a-z0-9]'), '');
    case 'record_label':
      var l = words(f);
      for (var i = 0; i < 2; i++) {
        l = l.replaceFirst(
          RegExp(r'\s+(records|recordings|music|ltd\.?|limited|label|inc\.?)$'),
          '',
        );
      }
      return l;
  }
  return words(f);
}

/// One tool's finding for a track: field → the value it wrote.
typedef Findings = Map<int, Map<String, String>>;

/// A merged suggestion before it is stored.
class MergedSuggestion {
  MergedSuggestion(
    this.trackId,
    this.field,
    this.value,
    this.confidence,
    this.evidence,
    this.tools,
  );
  final int trackId;
  final String field, value, evidence;
  final double confidence;
  final List<String> tools;
}

/// Merges every tool's findings: per track and field, the value most tools
/// agree on wins (ties: the more trusted tools). Confidence starts at the most
/// trusted agreeing tool's trust, gains 0.07 for each extra tool that agrees
/// and loses 0.12 when another tool disagrees.
List<MergedSuggestion> mergeFindings(Map<String, Findings> byTool) {
  final out = <MergedSuggestion>[];
  final tracks = {for (final f in byTool.values) ...f.keys};
  for (final id in tracks.toList()..sort()) {
    for (final field in taggerFields) {
      // agreement key → (display value, tools)
      final groups = <String, (String, List<String>)>{};
      for (final MapEntry(key: tool, value: f) in byTool.entries) {
        final v = f[id]?[field];
        if (v == null) continue;
        final g = groups[agreeKey(field, v)] ??= (v, <String>[]);
        g.$2.add(tool);
      }
      if (groups.isEmpty) continue;
      double trustOf(List<String> tools) => tools
          .map((t) => taggerById(t)?.trust[field] ?? 0.5)
          .fold(0.0, (a, b) => a > b ? a : b);
      final ranked = groups.values.toList()
        ..sort((a, b) {
          final n = b.$2.length.compareTo(a.$2.length);
          return n != 0 ? n : trustOf(b.$2).compareTo(trustOf(a.$2));
        });
      final (value, tools) = ranked.first;
      final others = ranked.skip(1).toList();
      var conf = trustOf(tools) + 0.07 * (tools.length - 1);
      if (others.isNotEmpty) conf -= 0.12;
      conf = conf.clamp(0.3, 0.97);
      String names(List<String> t) =>
          t.map((x) => taggerById(x)?.name ?? x).join(' + ');
      final evidence = StringBuffer(
        tools.length > 1
            ? '${names(tools)} agree'
            : '${names(tools)} found this',
      );
      for (final (v, t) in others) {
        evidence.write('; ${names(t)} said “$v”');
      }
      out.add(
        MergedSuggestion(
          id,
          field,
          value,
          conf,
          evidence.toString(),
          List.of(tools),
        ),
      );
    }
  }
  return out;
}

/// What one workspace holds: the tracks (id, original path, the original's
/// tags) and each tool's findings so far.
class TaggerWorkspace {
  TaggerWorkspace(this.dir, this.manifest);
  final String dir;
  final Map<String, Object?> manifest;

  static const manifestName = 'workspace.json';

  String get id => p.basename(dir);
  int get createdAt => (manifest['created_at'] as int?) ?? 0;
  String get label => '${manifest['label'] ?? ''}';
  List<Map<String, Object?>> get tracks =>
      ((manifest['tracks'] as List?) ?? const [])
          .cast<Map>()
          .map(Map<String, Object?>.from)
          .toList();

  /// Tool id → { track id → { field → value } }.
  Map<String, Findings> get findings {
    final raw = (manifest['findings'] as Map?) ?? const {};
    return {
      for (final MapEntry(:key, :value) in raw.entries)
        '$key': {
          for (final MapEntry(key: t, value: f) in (value as Map).entries)
            int.parse('$t'): Map<String, String>.from(f as Map),
        },
    };
  }

  /// Tool id → when its results were collected (ms), for tools that ran.
  Map<String, int> get collected => Map<String, int>.from(
    (manifest['collected'] as Map?) ?? const <String, int>{},
  );

  /// Tool id → its copies were made and handed to it (ms).
  Map<String, int> get opened => Map<String, int>.from(
    (manifest['opened'] as Map?) ?? const <String, int>{},
  );

  String toolDir(String tool) => p.join(dir, 'copies', tool);
  String logPath(String tool) => p.join(dir, 'logs', '$tool.log');

  /// Where [tool]'s copy of a track lives: its own folder per track, so file
  /// names never collide and each copy maps back to its track.
  String copyPath(String tool, Map<String, Object?> t) =>
      p.join(toolDir(tool), '${t['track_id']}', '${t['file_name']}');

  static TaggerWorkspace load(String dir) {
    final f = File(p.join(dir, manifestName));
    if (!f.existsSync()) _no('no workspace in $dir');
    return TaggerWorkspace(
      dir,
      Map<String, Object?>.from(jsonDecode(f.readAsStringSync()) as Map),
    );
  }

  void save() {
    final f = File(p.join(dir, manifestName));
    final tmp = File('${f.path}.part')
      ..writeAsStringSync(const JsonEncoder.withIndent(' ').convert(manifest));
    tmp.renameSync(f.path);
  }

  /// Makes [tool]'s own copies of every track (once). Each copy is checked
  /// by size; the originals are only read.
  Future<void> ensureCopies(String tool, [JobProgress? progress]) async {
    final list = tracks;
    progress?.total = list.length;
    for (final t in list) {
      if (await progress?.checkpoint() ?? false) return;
      final src = File('${t['path']}');
      final dst = File(copyPath(tool, t));
      if (!dst.existsSync() || dst.lengthSync() != src.lengthSync()) {
        dst.parent.createSync(recursive: true);
        await src.copy(dst.path);
        if (dst.lengthSync() != src.lengthSync()) {
          _no('copying ${t['file_name']} failed');
        }
      }
      progress?.tick();
    }
  }

  /// Reads [tool]'s copies back and records what differs from the originals.
  Findings collect(String tool) {
    final found = <int, Map<String, String>>{};
    for (final t in tracks) {
      final copy = File(copyPath(tool, t));
      if (!copy.existsSync()) continue;
      final Map<String, String> now;
      try {
        now = tagValues(readMediaMeta(copy.path));
      } on Object {
        continue; // a tool left the copy unreadable: nothing to learn from it
      }
      final before = Map<String, String>.from(
        (t['before'] as Map?) ?? const {},
      );
      final diff = <String, String>{
        for (final MapEntry(:key, :value) in now.entries)
          if (before[key] == null ||
              agreeKey(key, before[key]!) != agreeKey(key, value))
            key: value,
      };
      if (diff.isNotEmpty) found[t['track_id']! as int] = diff;
    }
    final all = Map<String, Object?>.from(
      (manifest['findings'] as Map?) ?? const {},
    );
    all[tool] = {
      for (final MapEntry(:key, :value) in found.entries) '$key': value,
    };
    manifest['findings'] = all;
    manifest['collected'] = {...collected, tool: nowMs()};
    save();
    return found;
  }
}

/// Runs a program and returns its exit code and output (injectable in tests).
typedef ToolRunner = Future<ProcessResult> Function(
  String exe,
  List<String> args, {
  Map<String, String>? environment,
  String? workingDirectory,
});

Future<ProcessResult> _runProcess(
  String exe,
  List<String> args, {
  Map<String, String>? environment,
  String? workingDirectory,
}) => Process.run(
  exe,
  args,
  environment: environment,
  workingDirectory: workingDirectory,
  runInShell: Platform.isWindows && !exe.toLowerCase().endsWith('.exe'),
);

/// The command line for an automatic tool on its copies.
(List<String>, Map<String, String>?) automaticCommand(
  TaggerWorkspace ws,
  String tool, {
  String? platforms,
  String? beetsPlugins,
}) {
  final dir = ws.toolDir(tool);
  switch (tool) {
    case 'onetagger':
      return (
        [
          'autotagger',
          '--path',
          dir,
          '--platforms',
          (platforms == null || platforms.trim().isEmpty)
              ? defaultOneTaggerPlatforms
              : platforms.replaceAll(' ', ''),
          '--tags',
          oneTaggerTags,
          '--overwrite',
          '--only-year',
          '--parse-filename',
        ],
        null,
      );
    case 'beets':
      // beets gets its own config and library inside the workspace, so the
      // DJ's own beets library and settings are never touched. It writes tags
      // into the copies in place (copy: no, move: no) and never asks.
      final home = p.join(ws.dir, 'beets');
      Directory(home).createSync(recursive: true);
      final plugins = (beetsPlugins ?? '')
          .split(RegExp(r'[\s,]+'))
          .where((x) => RegExp(r'^[a-z0-9_]+$').hasMatch(x))
          .toList();
      String yaml(String s) => "'${s.replaceAll("'", "''")}'";
      File(p.join(home, 'config.yaml')).writeAsStringSync(
        [
          'directory: ${yaml(p.join(home, 'unused'))}',
          'library: ${yaml(p.join(home, 'library.db'))}',
          'import:',
          '  copy: no',
          '  move: no',
          '  write: yes',
          '  quiet: yes',
          '  quiet_fallback: skip',
          '  resume: no',
          '  incremental: no',
          '  log: ${yaml(p.join(home, 'import.log'))}',
          if (plugins.isNotEmpty) 'plugins: ${plugins.join(' ')}',
          if (plugins.contains('lastgenre')) ...[
            'lastgenre:',
            '  auto: yes',
            '  force: yes',
          ],
          '',
        ].join('\n'),
      );
      return (
        ['-c', p.join(home, 'config.yaml'), 'import', '-q', '-s', dir],
        {'BEETSDIR': home},
      );
  }
  _no('${taggerById(tool)?.name ?? tool} is not an automatic tool');
}

/// The command that opens an interactive tool on its copies.
List<String> interactiveCommand(TaggerWorkspace ws, String tool) =>
    switch (tool) {
      // Picard loads every file and folder it is given
      'picard' => [ws.toolDir(tool)],
      // Mp3tag: /fp: opens a folder (with its subfolders)
      'mp3tag' => ['/fp:${ws.toolDir(tool)}'],
      _ => _no('${taggerById(tool)?.name ?? tool} is not an interactive tool'),
    };

/// Finds a tool: the path the DJ set, else PATH, else the usual install
/// locations. Null when it isn't installed.
String? findTool(
  TaggerDef def, {
  String? configured,
  Map<String, String>? env,
  bool? windows,
}) {
  final e = env ?? Platform.environment;
  final win = windows ?? Platform.isWindows;
  if (configured != null && configured.trim().isNotEmpty) {
    return File(configured).existsSync() ? configured : null;
  }
  final sep = win ? ';' : ':';
  for (final dir in (e['PATH'] ?? e['Path'] ?? '').split(sep)) {
    if (dir.isEmpty) continue;
    for (final n in def.exeNames) {
      for (final name in win ? ['$n.exe', '$n.cmd', '$n.bat'] : [n]) {
        final f = p.join(dir, name);
        if (File(f).existsSync()) return f;
      }
    }
  }
  if (win) {
    for (final raw in def.windowsPaths) {
      final parts = [
        for (final seg in raw.split(r'\'))
          seg.replaceAllMapped(RegExp(r'%([^%]+)%'), (m) => e[m[1]!] ?? ''),
      ];
      if (parts.first.isEmpty) continue; // the variable isn't set
      final path = p.joinAll(parts);
      if (File(path).existsSync()) return path;
    }
  }
  return null;
}

/// The background job that runs an automatic tool on its copies and reads
/// them back. Sendable values only (it runs in an isolate).
JobBody taggerJob(
  String wsDir,
  String tool,
  String exe, {
  String? platforms,
  String? beetsPlugins,
  Duration timeout = const Duration(hours: 2),
}) => (ctx) async {
  await runAutomaticTool(
    TaggerWorkspace.load(wsDir),
    tool,
    exe,
    progress: ctx,
    platforms: platforms,
    beetsPlugins: beetsPlugins,
    timeout: timeout,
  );
};

/// Copies, runs and collects one automatic tool. Its output goes to the
/// workspace's log; a failure says what the tool printed last.
Future<Findings> runAutomaticTool(
  TaggerWorkspace ws,
  String tool,
  String exe, {
  JobProgress? progress,
  String? platforms,
  String? beetsPlugins,
  ToolRunner run = _runProcess,
  Duration timeout = const Duration(hours: 2),
}) async {
  final name = taggerById(tool)?.name ?? tool;
  progress?.message = 'Copying tracks for $name…';
  await ws.ensureCopies(tool, progress);
  if (await progress?.checkpoint() ?? false) return {};
  ws.manifest['opened'] = {...ws.opened, tool: nowMs()};
  ws.save();
  progress?.message = 'Running $name on the copies…';
  final (args, env) = automaticCommand(
    ws,
    tool,
    platforms: platforms,
    beetsPlugins: beetsPlugins,
  );
  final r = await run(
    exe,
    args,
    environment: env,
    workingDirectory: ws.toolDir(tool),
  ).timeout(timeout);
  final log = File(ws.logPath(tool))..parent.createSync(recursive: true);
  log.writeAsStringSync(
    '\$ $exe ${args.join(' ')}\nexit ${r.exitCode}\n\n${r.stdout}\n${r.stderr}',
  );
  if (r.exitCode != 0) {
    String? lastLine(Object? out) => '$out'
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .lastOrNull;
    final last = lastLine(r.stderr) ?? lastLine(r.stdout);
    _no('$name stopped (exit ${r.exitCode})${last == null ? '' : ': $last'}');
  }
  progress?.message = 'Reading what $name found…';
  return ws.collect(tool);
}

/// Taggers for one catalogue: tool paths, workspaces and the merge into
/// Suggestions. Runs in the app; the heavy work runs in [taggerJob].
class TaggerService {
  TaggerService(this.cat, this.dataDir);
  final Catalogue cat;
  final String dataDir;

  String get root => p.join(dataDir, 'taggers');

  String? configuredPath(String tool) => cat.getSetting('tagger_path_$tool');

  void setPath(String tool, String? path) {
    if (taggerById(tool) == null) _no('unknown tool');
    final v = path?.trim() ?? '';
    if (v.isNotEmpty && !File(v).existsSync()) _no('that file does not exist');
    cat.setSetting('tagger_path_$tool', v);
  }

  String? path(String tool) =>
      findTool(taggerById(tool)!, configured: configuredPath(tool));

  bool enabled(String tool) => cat.getSetting('tagger_on_$tool') != '0';
  void setEnabled(String tool, bool on) =>
      cat.setSetting('tagger_on_$tool', on ? '1' : '0');

  String get oneTaggerPlatforms =>
      cat.getSetting('tagger_onetagger_platforms') ?? defaultOneTaggerPlatforms;
  set oneTaggerPlatforms(String v) {
    final ok = v
        .split(',')
        .map((x) => x.trim())
        .every((x) => RegExp(r'^[a-z0-9_]+$').hasMatch(x));
    if (!ok) {
      _no('list platform ids separated by commas, e.g. beatport,discogs');
    }
    cat.setSetting('tagger_onetagger_platforms', v.replaceAll(' ', ''));
  }

  String get beetsPlugins => cat.getSetting('tagger_beets_plugins') ?? '';
  set beetsPlugins(String v) => cat.setSetting('tagger_beets_plugins', v);

  /// Every tool with where it was found (null: not installed).
  List<Map<String, Object?>> tools() => [
    for (final d in taggerDefs)
      {
        'id': d.id,
        'name': d.name,
        'mode': d.mode.name,
        'path': path(d.id),
        'configured': configuredPath(d.id),
        'enabled': enabled(d.id),
      },
  ];

  /// Tracks for a workspace: present, readable files, in the given order.
  List<Map<String, Object?>> _trackRows(List<int> ids) {
    final out = <Map<String, Object?>>[];
    for (final id in ids) {
      final r = cat.db.select(
        "SELECT id, path, file_name FROM tracks WHERE id=? AND presence='present'",
        [id],
      );
      if (r.isEmpty || !File(r.first['path'] as String).existsSync()) continue;
      out.add({
        'track_id': id,
        'path': r.first['path'],
        'file_name': r.first['file_name'],
      });
    }
    return out;
  }

  /// Tracks missing a genre, BPM, key, year or label (the usual tagging job).
  List<int> incompleteTracks({int? limit}) => [
    for (final r in cat.db.select(
      'SELECT t.id FROM tracks t LEFT JOIN track_user u ON u.track_id=t.id '
      "WHERE t.presence='present' AND t.read_status='ok' AND t.media_kind IS NOT 'video' AND ("
      'COALESCE(u.genre, t.genre) IS NULL OR COALESCE(u.year, t.year) IS NULL OR '
      'COALESCE(u.bpm, t.bpm_tag) IS NULL OR COALESCE(u.musical_key, t.key_tag) IS NULL OR '
      'COALESCE(u.record_label, t.label) IS NULL) ORDER BY t.id LIMIT ?',
      [limit ?? 1 << 30],
    ))
      r['id'] as int,
  ];

  /// A new workspace for these tracks. The originals' tags are read once
  /// (read-only) so every tool is compared with the same starting point.
  TaggerWorkspace create(List<int> trackIds, {String label = ''}) {
    final rows = _trackRows(trackIds);
    if (rows.isEmpty) _no('none of those tracks can be read right now');
    final now = nowMs();
    final dir = p.join(root, 'ws-$now');
    Directory(dir).createSync(recursive: true);
    for (final t in rows) {
      try {
        t['before'] = tagValues(readMediaMeta('${t['path']}'));
      } on Object {
        t['before'] = <String, String>{};
      }
    }
    final ws = TaggerWorkspace(dir, {
      'created_at': now,
      'label': label,
      'tracks': rows,
      'findings': <String, Object?>{},
    })..save();
    return ws;
  }

  /// Workspaces, newest first.
  List<TaggerWorkspace> workspaces() {
    final d = Directory(root);
    if (!d.existsSync()) return const [];
    final out = <TaggerWorkspace>[];
    for (final e in d.listSync().whereType<Directory>()) {
      try {
        out.add(TaggerWorkspace.load(e.path));
      } on Object {
        // half-made folder: ignored
      }
    }
    return out..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  /// Removes a workspace (only copies live there; music is never inside).
  void remove(TaggerWorkspace ws) {
    if (!p.isWithin(root, ws.dir)) _no('not a tagger workspace');
    Directory(ws.dir).deleteSync(recursive: true);
  }

  /// Copies the tracks for an interactive tool and opens it on them.
  Future<void> openInteractive(TaggerWorkspace ws, String tool) async {
    final exe = path(tool) ?? _no('${taggerById(tool)!.name} was not found');
    await ws.ensureCopies(tool);
    ws.manifest['opened'] = {...ws.opened, tool: nowMs()};
    ws.save();
    await Process.start(
      exe,
      interactiveCommand(ws, tool),
      mode: ProcessStartMode.detached,
    );
  }

  /// Merges every tool's findings in [ws] into pending Suggestions (source
  /// "taggers"). Returns how many suggestions were made or refreshed.
  int merge(TaggerWorkspace ws) {
    final lib = LibraryService(cat);
    var n = 0;
    for (final m in mergeFindings(ws.findings)) {
      final row = lib.row(m.trackId);
      if (row == null) continue;
      final current = switch (m.field) {
        'title' => row.title,
        'artist' => row.artist,
        'album' => row.album,
        'genre' => row.genre,
        'year' => row.year?.toString(),
        'original_year' => row.originalYear?.toString(),
        'bpm' => row.bpm == null ? null : rustNumber(row.bpm!),
        'key' => row.key,
        'record_label' =>
          cat.db.select(
                'SELECT COALESCE(u.record_label, t.label) AS v FROM tracks t '
                'LEFT JOIN track_user u ON u.track_id=t.id WHERE t.id=?',
                [m.trackId],
              ).firstOrNull?['v']
              as String?,
        _ => null,
      };
      if (current != null &&
          agreeKey(m.field, current) == agreeKey(m.field, m.value)) {
        continue; // the catalogue already says this
      }
      insertSuggestion(
        cat,
        m.trackId,
        m.field,
        current,
        m.value,
        'taggers',
        m.evidence,
        m.confidence,
      );
      n++;
    }
    return n;
  }
}
