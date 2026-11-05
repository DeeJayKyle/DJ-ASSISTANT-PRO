import 'dart:math' as math;

import 'genres.dart';
import 'names.dart';

/// Ordering Quick Prep playlists (1.x `src/lib/quick/setlist.ts`) and export
/// layouts (`layout.ts`).
class SetTrack {
  const SetTrack(
    this.id,
    this.bpm,
    this.camelot,
    this.energy, [
    this.genre = '',
  ]);
  final String id;
  final double bpm;
  final String camelot, genre;
  final double energy;
}

/// JavaScript's Array.sort is stable; Dart's List.sort is not guaranteed to be.
List<T> stableSorted<T>(Iterable<T> items, int Function(T a, T b) cmp) {
  final l = items.toList();
  final idx = List.generate(l.length, (i) => i)
    ..sort((a, b) {
      final c = cmp(l[a], l[b]);
      return c != 0 ? c : a.compareTo(b);
    });
  return [for (final i in idx) l[i]];
}

int _n(num v) => v < 0 ? -1 : (v > 0 ? 1 : 0);
double _or(double v, double d) => v == 0 || v.isNaN ? d : v;
int _locale(String a, String b) {
  final c = a.toLowerCase().compareTo(b.toLowerCase());
  return c != 0 ? c : a.compareTo(b);
}

List<T> byAscendingBpm<T extends SetTrack>(List<T> t) => stableSorted(
  t,
  (a, b) => _n((_or(a.bpm, 999) - _or(b.bpm, 999))) != 0
      ? _n(_or(a.bpm, 999) - _or(b.bpm, 999))
      : _n(a.energy - b.energy),
);
List<T> byDescendingBpm<T extends SetTrack>(List<T> t) =>
    stableSorted(t, (a, b) => _n(_or(b.bpm, 0) - _or(a.bpm, 0)));
List<T> byGenre<T extends SetTrack>(List<T> t) => stableSorted(t, (a, b) {
  final f = _locale(genreFamily(a.genre), genreFamily(b.genre));
  if (f != 0) return f;
  final g = _locale(a.genre, b.genre);
  if (g != 0) return g;
  return _n(_or(a.bpm, 999) - _or(b.bpm, 999));
});

int _camelotOrder(String c) {
  final m = RegExp(r'^(\d+)([AB])$').firstMatch(c);
  return m == null ? 999 : int.parse(m[1]!) * 2 + (m[2] == 'B' ? 1 : 0);
}

List<T> byKey<T extends SetTrack>(List<T> t) => stableSorted(t, (a, b) {
  final c = _camelotOrder(a.camelot) - _camelotOrder(b.camelot);
  return c != 0 ? c : _n(a.bpm - b.bpm);
});

/// How smoothly b follows a: harmonic match, a small tempo change, and energy that doesn't drop much.
double transitionCost(SetTrack a, SetTrack b) {
  final harmonic = compatibleCamelot(a.camelot).contains(b.camelot) ? 0 : 3;
  final tempo = a.bpm != 0 && b.bpm != 0
      ? [
              (a.bpm - b.bpm).abs(),
              (a.bpm - b.bpm * 2).abs(),
              (a.bpm * 2 - b.bpm).abs(),
            ].reduce(math.min) /
            2
      : 2.0;
  final energyDrop = math.max(0, a.energy - b.energy) * 1.5;
  return harmonic + tempo + energyDrop;
}

/// Warm-up → peak: starts with the calmest, slowest track and keeps choosing
/// the next track that mixes in best while the energy builds.
List<T> warmupToPeak<T extends SetTrack>(List<T> tracks) {
  if (tracks.length < 3) {
    return stableSorted(
      tracks,
      (a, b) => _n(a.energy - b.energy) != 0
          ? _n(a.energy - b.energy)
          : _n(a.bpm - b.bpm),
    );
  }
  final left = stableSorted(
    tracks,
    (a, b) => _n(a.energy - b.energy) != 0
        ? _n(a.energy - b.energy)
        : _n(_or(a.bpm, 999) - _or(b.bpm, 999)),
  );
  final out = [left.removeAt(0)];
  while (left.isNotEmpty) {
    final cur = out.last;
    // Look ahead only among the next calmest tracks so the arc keeps building.
    final window = left.sublist(
      0,
      math.min(left.length, math.max(3, (left.length / 3).ceil())),
    );
    var best = window.first;
    var bestCost = double.infinity;
    for (final t in window) {
      final c = transitionCost(cur, t) + math.max(0, t.energy - cur.energy - 2);
      if (c < bestCost) {
        bestCost = c;
        best = t;
      }
    }
    out.add(best);
    left.remove(best);
  }
  return out;
}

/// Average transition cost of an ordering (lower is smoother).
double setCost(List<SetTrack> t) {
  if (t.length < 2) return 0;
  var s = 0.0;
  for (var i = 1; i < t.length; i++) {
    s += transitionCost(t[i - 1], t[i]);
  }
  return s / (t.length - 1);
}

/// 'ascending-bpm' | 'descending-bpm' | 'warmup-peak' | 'genre' | 'key' | 'energy-up' | 'energy-down'
String? parseSortRequest(String text) {
  final t = text.toLowerCase();
  bool m(String re) => RegExp(re).hasMatch(t);
  if (m(r'warm\s*-?\s*up|build|journey|peak|set\b') && !m('genre')) {
    return 'warmup-peak';
  }
  if (m('genre|style')) return 'genre';
  if (m(r'harmonic|camelot|\bkey\b')) return 'key';
  if (m(
    r'(bpm|tempo|speed).*(desc|high|fast|down)|(desc|fast|high).*(bpm|tempo)',
  )) {
    return 'descending-bpm';
  }
  if (m('bpm|tempo|speed|slow')) return 'ascending-bpm';
  if (m(r'energy.*(down|desc|cool|low)|cool\s*down|wind\s*down')) {
    return 'energy-down';
  }
  if (m('energy')) return 'energy-up';
  return null;
}

List<T> applySort<T extends SetTrack>(String cmd, List<T> tracks) =>
    switch (cmd) {
      'ascending-bpm' => byAscendingBpm(tracks),
      'descending-bpm' => byDescendingBpm(tracks),
      'warmup-peak' => warmupToPeak(tracks),
      'genre' => byGenre(tracks),
      'key' => byKey(tracks),
      'energy-up' => stableSorted(
        tracks,
        (a, b) => _n(a.energy - b.energy) != 0
            ? _n(a.energy - b.energy)
            : _n(a.bpm - b.bpm),
      ),
      _ => stableSorted(
        tracks,
        (a, b) => _n(b.energy - a.energy) != 0
            ? _n(b.energy - a.energy)
            : _n(b.bpm - a.bpm),
      ),
    };

/// Energy roles for bins ('Warm Up' | 'Groove' | 'Peak Time'), spread over the library.
Map<String, String> assignRoles(List<SetTrack> tracks) {
  final sorted = stableSorted(
    tracks,
    (a, b) => _n(a.energy - b.energy) != 0
        ? _n(a.energy - b.energy)
        : _n(a.bpm - b.bpm),
  );
  final roles = <String, String>{};
  for (var i = 0; i < sorted.length; i++) {
    final t = sorted[i];
    roles[t.id] = tracks.length < 3
        ? (t.energy <= 4 ? 'Warm Up' : (t.energy >= 8 ? 'Peak Time' : 'Groove'))
        : (i < sorted.length / 3
              ? 'Warm Up'
              : (i < 2 * sorted.length / 3 ? 'Groove' : 'Peak Time'));
  }
  return roles;
}

// ---- export layouts

class LayoutTrack {
  const LayoutTrack(this.id, this.name, this.genre, this.bpm);
  final int id;
  final CleanName name;
  final String genre;
  final double bpm;
}

sealed class Layout {
  const Layout();
}

class CleanLayout extends Layout {
  const CleanLayout();
}

class PlaylistLayout extends Layout {
  const PlaylistLayout(this.name, this.order, {this.numbered = false});
  final String name;
  final List<int> order;
  final bool numbered;
}

class GenresLayout extends Layout {
  const GenresLayout({this.families = false});
  final bool families;
}

class FoldersLayout extends Layout {
  const FoldersLayout(this.bins);
  final List<(String, String, List<int>)> bins;
}

class PackLayout {
  PackLayout(this.items, this.playlists);
  final List<(int, String, String)> items; // (track_id, folder, name)
  final List<(String, String, List<int>)> playlists; // (name, path, track_ids)
}

String _folder(String s) => safeFileName(s, 80);

/// Folders, file names and playlists for one of the four Quick Prep paths.
PackLayout buildLayout(
  List<LayoutTrack> tracks,
  Layout layout,
  NameFormat format,
) {
  final byId = {for (final t in tracks) t.id: t};
  final items = <(int, String, String)>[];
  final playlists = <(String, String, List<int>)>[];
  String file(LayoutTrack t, [String prefix = '']) =>
      '$prefix${safeFileName(formatName(t.name, format))}';
  switch (layout) {
    case CleanLayout():
      for (final t in tracks) {
        items.add((t.id, '', file(t)));
      }
      playlists.add((
        'All tracks',
        'All tracks.m3u8',
        [for (final t in tracks) t.id],
      ));
    case PlaylistLayout(:final name, :final order, :final numbered):
      final dir = _folder(name.isEmpty ? 'Playlist' : name);
      final ordered = [for (final id in order) ?byId[id]];
      final width = math.max(2, '${ordered.length}'.length);
      for (var i = 0; i < ordered.length; i++) {
        items.add((
          ordered[i].id,
          dir,
          file(
            ordered[i],
            numbered ? '${'${i + 1}'.padLeft(width, '0')} ' : '',
          ),
        ));
      }
      playlists.add((
        name.isEmpty ? 'Playlist' : name,
        '$dir/$dir.m3u8',
        [for (final t in ordered) t.id],
      ));
    case GenresLayout(:final families):
      final groups = <String, List<LayoutTrack>>{};
      for (final t in tracks) {
        final g = families
            ? genreFamily(t.genre)
            : (t.genre.isEmpty ? 'Other' : t.genre);
        groups.putIfAbsent(g, () => []).add(t);
      }
      final keys = groups.keys.toList()..sort(_locale);
      for (final g in keys) {
        final dir = _folder(g);
        final sorted = stableSorted(
          groups[g]!,
          (a, b) => _n(_or(a.bpm, 999) - _or(b.bpm, 999)),
        );
        for (final t in sorted) {
          items.add((t.id, dir, file(t)));
        }
        playlists.add((
          g,
          'Playlists/$dir.m3u8',
          [for (final t in sorted) t.id],
        ));
      }
    case FoldersLayout(:final bins):
      final used = <int>{};
      for (final (main, sub, ids) in bins) {
        final list = [
          for (final id in ids)
            if (byId[id] case final t? when !used.contains(t.id)) t,
        ];
        if (list.isEmpty) continue;
        final dir = sub.isNotEmpty
            ? '${_folder(main)}/${_folder(sub)}'
            : _folder(main);
        final label = sub.isNotEmpty ? '$main - $sub' : main;
        for (final t in list) {
          used.add(t.id);
          items.add((t.id, dir, file(t)));
        }
        playlists.add((
          label,
          'Playlists/${_folder(label)}.m3u8',
          [for (final t in list) t.id],
        ));
      }
      final rest = tracks.where((t) => !used.contains(t.id)).toList();
      if (rest.isNotEmpty) {
        for (final t in rest) {
          items.add((t.id, 'Unsorted', file(t)));
        }
        playlists.add((
          'Unsorted',
          'Playlists/Unsorted.m3u8',
          [for (final t in rest) t.id],
        ));
      }
  }
  return PackLayout(items, playlists);
}
