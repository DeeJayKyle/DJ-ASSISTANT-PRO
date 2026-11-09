import 'package:xml/xml.dart';

import 'catalogue.dart';
import 'crates.dart';
import 'track_match.dart';

/// Read-only import of a rekordbox library exported as XML (rekordbox:
/// File → Export Collection in xml format). Its playlists and folders
/// become manual crates under "rekordbox import", holding the matching
/// tracks from this library. rekordbox's own files are never touched, and
/// nothing about the tracks themselves is changed.
///
/// The XML layout (rekordbox's published format): `COLLECTION` holds
/// `TRACK` elements (TrackID, Name, Artist, Location as a `file://localhost/`
/// URL, TotalTime in seconds, AverageBpm, Tonality) with `POSITION_MARK`
/// children for cues; `PLAYLISTS` holds a tree of `NODE` elements, Type 0 a
/// folder and Type 1 a playlist whose `TRACK` children carry a `Key` that is
/// a TrackID (KeyType 0) or a Location (KeyType 1).
class RekordboxImportException implements Exception {
  RekordboxImportException(this.message);
  final String message;
  @override
  String toString() => message;
}

class RbCue {
  const RbCue({required this.startMs, this.endMs, this.slot, this.name = ''});
  final int startMs;
  final int? endMs;

  /// Hot cue pad 1–8; null for a memory cue.
  final int? slot;
  final String name;
}

class RbTrack {
  const RbTrack({
    required this.id,
    this.title,
    this.artist,
    this.path,
    this.durationSec,
    this.bpm,
    this.key,
    this.cues = const [],
  });
  final String id;
  final String? title, artist, path, key;
  final double? durationSec, bpm;
  final List<RbCue> cues;
}

class RbNode {
  RbNode(this.name, {this.folder = false});
  final String name;
  final bool folder;
  final children = <RbNode>[];

  /// Track ids (KeyType 0) or locations (KeyType 1), in playlist order.
  final keys = <String>[];
  bool byLocation = false;
}

class RbLibrary {
  RbLibrary(this.tracks, this.root);
  final Map<String, RbTrack> tracks;
  final RbNode root;
}

/// A `file://localhost/...` location as a local path.
String? rekordboxLocationPath(String? loc) {
  if (loc == null || loc.isEmpty) return null;
  var s = loc;
  for (final prefix in ['file://localhost', 'file://']) {
    if (s.startsWith(prefix)) {
      s = s.substring(prefix.length);
      break;
    }
  }
  try {
    s = Uri.decodeFull(s);
  } on ArgumentError {
    // keep the text as it is
  }
  // "/C:/Music/x.mp3" → "C:/Music/x.mp3"
  if (RegExp(r'^/[A-Za-z]:/').hasMatch(s)) s = s.substring(1);
  return s;
}

double? _num(String? s) => s == null ? null : double.tryParse(s);

RbLibrary parseRekordboxXml(String text) {
  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(text);
  } on XmlException catch (e) {
    throw RekordboxImportException(
      'This file is not readable XML (${e.message}).',
    );
  }
  final top = doc.rootElement;
  if (top.name.local != 'DJ_PLAYLISTS') {
    throw RekordboxImportException(
      'This is not a rekordbox XML file (export it from rekordbox with File → Export Collection in xml format).',
    );
  }
  final tracks = <String, RbTrack>{};
  for (final col in top.findElements('COLLECTION')) {
    for (final t in col.findElements('TRACK')) {
      final id = t.getAttribute('TrackID');
      if (id == null) continue;
      tracks[id] = RbTrack(
        id: id,
        title: t.getAttribute('Name'),
        artist: t.getAttribute('Artist'),
        path: rekordboxLocationPath(t.getAttribute('Location')),
        durationSec: _num(t.getAttribute('TotalTime')),
        bpm: _num(t.getAttribute('AverageBpm')),
        key: t.getAttribute('Tonality'),
        cues: [
          for (final m in t.findElements('POSITION_MARK'))
            if (_num(m.getAttribute('Start')) != null)
              RbCue(
                startMs: (_num(m.getAttribute('Start'))! * 1000).round(),
                endMs: _num(m.getAttribute('End')) == null
                    ? null
                    : (_num(m.getAttribute('End'))! * 1000).round(),
                slot: switch (int.tryParse(m.getAttribute('Num') ?? '')) {
                  final n? when n >= 0 && n < 8 => n + 1,
                  _ => null,
                },
                name: m.getAttribute('Name') ?? '',
              ),
        ],
      );
    }
  }
  final root = RbNode('ROOT', folder: true);
  void walk(XmlElement e, RbNode into) {
    for (final n in e.findElements('NODE')) {
      final type = n.getAttribute('Type');
      final node = RbNode(n.getAttribute('Name') ?? '', folder: type == '0');
      if (type == '1') {
        node.byLocation = n.getAttribute('KeyType') == '1';
        for (final t in n.findElements('TRACK')) {
          final k = t.getAttribute('Key');
          if (k != null) node.keys.add(k);
        }
      } else {
        walk(n, node);
      }
      into.children.add(node);
    }
  }

  for (final pl in top.findElements('PLAYLISTS')) {
    for (final r in pl.findElements('NODE')) {
      // the outer node is rekordbox's own ROOT folder
      walk(r, root);
    }
  }
  return RbLibrary(tracks, root);
}

class RekordboxImportService {
  RekordboxImportService(this.cat);
  final Catalogue cat;

  /// Imports [xml]'s playlists as crates. Returns a per-playlist report.
  Map<String, Object?> importXml(String xml, {String label = 'rekordbox'}) {
    if (xml.length > 400 * 1024 * 1024) {
      throw RekordboxImportException('file is too large');
    }
    final lib = parseRekordboxXml(xml);
    final matcher = libraryMatcher(cat);
    final idFor = <String, TrackMatch?>{};
    TrackMatch? matchTrack(RbTrack t) => idFor.putIfAbsent(
      t.id,
      () => matcher.match(
        MatchEntry(
          path: t.path,
          artist: t.artist,
          title: t.title,
          durationSec: t.durationSec,
        ),
      ),
    );
    final byPath = {
      for (final t in lib.tracks.values)
        if (t.path != null) t.path!: t,
    };

    final crates = CratesService(cat);
    int? find(String name, int? parent) {
      final r = cat.db.select(
        'SELECT id FROM crates WHERE name=? AND parent_id IS ?',
        [name, parent],
      );
      return r.isEmpty ? null : r.first['id'] as int;
    }

    String clip(String s) => String.fromCharCodes(
      (s.trim().isEmpty ? 'Untitled' : s.trim()).runes.take(120),
    );
    final topName = clip('rekordbox import ($label)');
    final top =
        find(topName, null) ??
        crates
            .create(
              CrateInput(
                name: topName,
                kind: 'manual',
                color: 'blue',
                category: 'Imported',
              ),
            )
            .id;
    final report = <Map<String, Object?>>[];
    var likely = 0;
    void walk(RbNode node, int parent, String trail) {
      for (final c in node.children) {
        final name = clip(c.name);
        final id =
            find(name, parent) ??
            crates
                .create(
                  CrateInput(name: name, kind: 'manual', parentId: parent),
                )
                .id;
        final path = trail.isEmpty ? name : '$trail / $name';
        if (c.folder) {
          walk(c, id, path);
          continue;
        }
        final matched = <int>[];
        final missing = <String>[];
        var probable = 0;
        for (final k in c.keys) {
          final t = c.byLocation
              ? byPath[rekordboxLocationPath(k)] ??
                    RbTrack(id: 'loc:$k', path: rekordboxLocationPath(k))
              : lib.tracks[k];
          if (t == null) continue;
          final m = matchTrack(t);
          if (m == null) {
            missing.add(
              [t.artist, t.title].whereType<String>().join(' — ').isEmpty
                  ? (t.path ?? k)
                  : [t.artist, t.title].whereType<String>().join(' — '),
            );
            continue;
          }
          if (!m.sure) probable++;
          matched.add(m.trackId);
        }
        likely += probable;
        crates.addTracks(id, matched);
        report.add({
          'playlist': path,
          'tracks': c.keys.length,
          'matched': matched.length,
          'likely': probable,
          'missing': missing.length,
          'missing_sample': missing.take(5).toList(),
        });
      }
    }

    walk(lib.root, top, '');
    final cues = lib.tracks.values.fold<int>(0, (n, t) => n + t.cues.length);
    return {
      'parent_id': top,
      'collection': lib.tracks.length,
      'playlists': report,
      'likely': likely,
      'cues': cues,
      'note': "The rekordbox file was only read. Tracks not in your DJ Assistant library (or on a drive that is not added) are listed as missing.",
    };
  }
}
