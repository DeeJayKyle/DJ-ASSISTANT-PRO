import 'catalogue.dart';
import 'library.dart';
import 'library_edit.dart';
import 'text.dart';

/// Fields a suggestion may target (1.x `suggest::FIELDS`).
const suggestionFields = [
  'title',
  'artist',
  'album',
  'genre',
  'year',
  'original_year',
  'bpm',
  'key',
  'version_label',
  'record_label',
];

/// Records (or refreshes) a pending suggestion. Nothing is written to files; the
/// DJ accepts suggestions into the catalogue. Ignored when the value is empty or
/// already the current one.
void insertSuggestion(
  Catalogue cat,
  int trackId,
  String field,
  String? current,
  String value,
  String source,
  String evidence,
  double confidence,
) {
  if (!suggestionFields.contains(field) || value.trim().isEmpty) return;
  if (current != null && fold(current.trim()) == fold(value.trim())) return;
  cat.db.execute(
    'INSERT INTO suggestions (track_id, field, current_value, suggested_value, source, evidence, confidence, status, created_at) '
    "VALUES (?,?,?,?,?,?,?,'pending',?) "
    'ON CONFLICT(track_id, field, suggested_value, source) DO UPDATE SET current_value=excluded.current_value, '
    'evidence=excluded.evidence, confidence=excluded.confidence',
    [
      trackId,
      field,
      current,
      value.trim(),
      source,
      evidence,
      confidence.clamp(0.0, 1.0),
      nowMs(),
    ],
  );
}

/// A number as Rust's `{}` prints it ("140", "180.5"), so stored text matches 1.x.
String rustNumber(double v) => (v == v.truncateToDouble() && v.abs() < 1e15)
    ? v.toInt().toString()
    : v.toString();

class SuggestionException implements Exception {
  SuggestionException(this.message);
  final String message;
  @override
  String toString() => message;
}

class Suggestion {
  Suggestion(Map<String, Object?> r)
    : id = r['id'] as int,
      trackId = r['track_id'] as int,
      track = r['track'] as String,
      field = r['field'] as String,
      currentValue = r['current_value'] as String?,
      suggestedValue = r['suggested_value'] as String,
      source = r['source'] as String,
      evidence = r['evidence'] as String?,
      confidence = (r['confidence'] as num?)?.toDouble(),
      status = r['status'] as String,
      createdAt = r['created_at'] as int;
  final int id, trackId, createdAt;
  final String track, field, suggestedValue, source, status;
  final String? currentValue, evidence;
  final double? confidence;
}

/// The fields auto-prep may fill in the catalogue.
const autoFields = [
  'bpm',
  'key',
  'title',
  'artist',
  'album',
  'genre',
  'year',
  'original_year',
  'record_label',
  'version_label',
];

const knownGenres = [
  'afrobeats',
  'afrobeat',
  'afro house',
  'amapiano',
  'house',
  'deep house',
  'tech house',
  'techno',
  'hip hop', //
  'hip-hop',
  'rap',
  'r&b',
  'rnb',
  'pop',
  'dancehall',
  'reggae',
  'reggaeton',
  'latin',
  'soca',
  'gospel',
  'jazz',
  'soul',
  'funk',
  'disco',
  'drum & bass',
  'dnb',
  'dubstep',
  'trap',
  'edm',
  'garage',
  'uk garage',
  'kwaito',
  'gqom',
  'bongo flava',
  'zouk',
  'kizomba',
  'rock',
  'country',
  'ambient',
  'lounge',
  'throwbacks',
  'open format',
];

String _stripTrackNumber(String s) {
  final t = s.trimLeft();
  var digits = 0;
  while (digits < t.length &&
      t.codeUnitAt(digits) >= 48 &&
      t.codeUnitAt(digits) <= 57) {
    digits++;
  }
  if (digits >= 1 && digits <= 3) {
    final rest = t.substring(digits).replaceFirst(RegExp(r'^[.)\-_ ]+'), '');
    if (rest.isNotEmpty && rest.length < t.length) return rest;
  }
  return t;
}

/// "Artist - Title (Version)" style file names (1.x `parse_filename`).
(String, String)? parseFilename(String stem) {
  final s = _stripTrackNumber(stem.replaceAll('_', ' '));
  for (final sep in [' - ', ' – ', ' — ']) {
    final i = s.indexOf(sep);
    if (i >= 0) {
      final a = s.substring(0, i).trim(),
          t = s.substring(i + sep.length).trim();
      if (a.isNotEmpty && t.isNotEmpty) return (a, t);
    }
  }
  return null;
}

/// A year in brackets, "(2019)" or "[2019]", between 1900 and 2100.
int? yearIn(String s) {
  final m = RegExp(r'[(\[](\d{4})[)\]]').allMatches(s);
  for (final x in m) {
    final y = int.parse(x.group(1)!);
    if (y >= 1900 && y <= 2100) return y;
  }
  return null;
}

class SuggestionsService {
  SuggestionsService(this.cat);
  final Catalogue cat;

  List<Suggestion> list({String? status, int? trackId, int limit = 500}) => cat
      .db
      .select(
        "SELECT s.id, s.track_id, COALESCE(COALESCE(u.artist, t.artist) || ' — ', '') || COALESCE(u.title, t.title, t.file_name) AS track, "
        's.field, s.current_value, s.suggested_value, s.source, s.evidence, s.confidence, s.status, s.created_at '
        'FROM suggestions s JOIN tracks t ON t.id=s.track_id LEFT JOIN track_user u ON u.track_id=t.id '
        'WHERE (? IS NULL OR s.status=?) AND (? IS NULL OR s.track_id=?) '
        "ORDER BY s.status='pending' DESC, s.confidence DESC, s.id LIMIT ?",
        [status, status, trackId, trackId, limit.clamp(1, 50000)],
      )
      .map(Suggestion.new)
      .toList();

  Map<String, int> counts() => {
    for (final r in cat.db.select(
      'SELECT status, COUNT(*) AS n FROM suggestions GROUP BY status',
    ))
      r['status'] as String: r['n'] as int,
  };

  /// Accepts a suggestion (optionally edited) into the catalogue; other pending
  /// suggestions for the same field are superseded.
  void accept(int id, {String? edited}) {
    final rows = cat.db.select(
      'SELECT track_id, field, suggested_value FROM suggestions WHERE id=?',
      [id],
    );
    if (rows.isEmpty) throw SuggestionException('suggestion not found');
    final r = rows.first;
    final trackId = r['track_id'] as int, field = r['field'] as String;
    final v = edited?.trim() ?? r['suggested_value'] as String;
    if (v.isEmpty) throw SuggestionException('value is empty');
    double num(String s) =>
        double.tryParse(s) ??
        (throw SuggestionException("'$s' is not a number"));
    final patch = switch (field) {
      'title' ||
      'artist' ||
      'album' ||
      'genre' ||
      'key' ||
      'version_label' ||
      'record_label' => {field: v},
      'year' || 'original_year' => {field: num(v).toInt()},
      'bpm' => {'bpm': num(v)},
      _ => throw SuggestionException('unknown field'),
    };
    LibraryService(cat).updateUserFields([trackId], patch);
    final now = nowMs();
    cat.db.execute(
      "UPDATE suggestions SET status='accepted', decided_at=? WHERE id=?",
      [now, id],
    );
    cat.db.execute(
      "UPDATE suggestions SET status='rejected', decided_at=? WHERE track_id=? AND field=? AND status='pending' AND id<>?",
      [now, trackId, field, id],
    );
  }

  void reject(int id) {
    cat.db.execute(
      "UPDATE suggestions SET status='rejected', decided_at=? WHERE id=?",
      [nowMs(), id],
    );
    if (cat.db.updatedRows == 0) {
      throw SuggestionException('suggestion not found');
    }
  }

  void reset(int id) => cat.db.execute(
    "UPDATE suggestions SET status='pending', decided_at=NULL WHERE id=?",
    [id],
  );

  bool _stillPending(int id) =>
      cat.db.select(
        "SELECT status='pending' AS p FROM suggestions WHERE id=?",
        [id],
      ).first['p'] ==
      1;

  int acceptBulk(double min, {String? source}) {
    var n = 0;
    for (final s in list(status: 'pending', limit: 50000)) {
      if ((s.confidence ?? 0) < min || (source != null && s.source != source)) {
        continue;
      }
      if (!_stillPending(s.id)) continue;
      try {
        accept(s.id);
        n++;
      } on Exception {
        // a value the catalogue refuses is left pending
      }
    }
    return n;
  }

  /// Fills empty fields from the best suggestion at or above [minFill]; replaces an
  /// existing value only at or above [minReplace].
  int acceptRecommended(double minFill, double minReplace) {
    var n = 0;
    for (final s in list(status: 'pending', limit: 50000)) {
      if (!autoFields.contains(s.field)) continue;
      final empty = s.currentValue == null || s.currentValue!.trim().isEmpty;
      if ((s.confidence ?? 0) < (empty ? minFill : minReplace)) continue;
      if (!_stillPending(s.id)) continue;
      try {
        accept(s.id);
        n++;
      } on Exception {
        // left pending
      }
    }
    return n;
  }

  /// Offline suggestions: file names, folder genres, years in names and the most
  /// common spellings in the library. Returns how many were created.
  int generateLocal() {
    int count() =>
        cat.db.select('SELECT COUNT(*) AS n FROM suggestions').first['n']
            as int;
    final before = count();
    final rows = cat.db.select(
      'SELECT t.id, COALESCE(u.title, t.title) AS title, COALESCE(u.artist, t.artist) AS artist, '
      'COALESCE(u.genre, t.genre) AS genre, COALESCE(u.year, t.year) AS year, t.file_name, t.rel_path '
      "FROM tracks t LEFT JOIN track_user u ON u.track_id=t.id WHERE t.presence='present' AND t.read_status='ok'",
    );
    String artistKey(String a) =>
        fold(a.trim())
            .split(RegExp(r'\s+'))
            .where((w) => w.isNotEmpty)
            .join(' ');
    String genreKey(String g) =>
        fold(g).runes
            .where((r) => _isAlnumRune(r))
            .map(String.fromCharCode)
            .join();
    final artistForms = <String, Map<String, int>>{},
        genreForms = <String, Map<String, int>>{};
    for (final r in rows) {
      final a = r['artist'] as String?, g = r['genre'] as String?;
      if (a != null) {
        final m = artistForms[artistKey(a)] ??= {};
        m[a.trim()] = (m[a.trim()] ?? 0) + 1;
      }
      if (g != null) {
        final m = genreForms[genreKey(g)] ??= {};
        m[g.trim()] = (m[g.trim()] ?? 0) + 1;
      }
    }
    // Most common form; ties go to the longer spelling (1.x max_by_key (count, len)).
    (String, int)? best(Map<String, int>? m) {
      if (m == null || m.isEmpty) return null;
      final e = m.entries.reduce((x, y) {
        if (y.value != x.value) return y.value > x.value ? y : x;
        if (y.key.length != x.key.length) {
          return y.key.length > x.key.length ? y : x;
        }
        return y; // max_by keeps the last of equal maxima
      });
      return (e.key, e.value);
    }

    for (final r in rows) {
      final id = r['id'] as int,
          file = r['file_name'] as String,
          rel = r['rel_path'] as String;
      final title = r['title'] as String?,
          artist = r['artist'] as String?,
          genre = r['genre'] as String?;
      final dot = file.lastIndexOf('.');
      final stem = dot > 0 ? file.substring(0, dot) : file;
      final parsed = parseFilename(stem);
      if (parsed != null) {
        if (artist == null) {
          insertSuggestion(
            cat,
            id,
            'artist',
            null,
            parsed.$1,
            'File name',
            'Parsed from the file name "$file".',
            0.6,
          );
        }
        if (title == null) {
          insertSuggestion(
            cat,
            id,
            'title',
            null,
            parsed.$2,
            'File name',
            'Parsed from the file name "$file".',
            0.6,
          );
        }
      } else if (title == null) {
        insertSuggestion(
          cat,
          id,
          'title',
          null,
          _stripTrackNumber(stem).trim(),
          'File name',
          'Taken from the file name.',
          0.4,
        );
      }
      if (r['year'] == null) {
        final y = yearIn(file) ?? yearIn(rel);
        if (y != null) {
          insertSuggestion(
            cat,
            id,
            'year',
            null,
            '$y',
            'File name',
            'A year in brackets appears in the file or folder name.',
            0.45,
          );
        }
      }
      if (genre == null) {
        final folders = rel.split(RegExp(r'[/\\]'));
        for (final f in folders.reversed.skip(1)) {
          if (knownGenres.contains(fold(f.trim()))) {
            insertSuggestion(
              cat,
              id,
              'genre',
              null,
              f.trim(),
              'Folder name',
              'The file is in a folder called "${f.trim()}".',
              0.4,
            );
            break;
          }
        }
      }
      if (artist != null) {
        final b = best(artistForms[artistKey(artist)]);
        if (b != null && b.$1 != artist.trim() && b.$2 >= 2) {
          insertSuggestion(
            cat,
            id,
            'artist',
            artist,
            b.$1,
            'Library consistency',
            '"${b.$1}" is how this artist is written on ${b.$2} other tracks.',
            0.55,
          );
        }
      }
      if (genre != null) {
        final b = best(genreForms[genreKey(genre)]);
        if (b != null && b.$1 != genre.trim() && b.$2 >= 2) {
          insertSuggestion(
            cat,
            id,
            'genre',
            genre,
            b.$1,
            'Library consistency',
            '"${b.$1}" is the spelling used on ${b.$2} other tracks.',
            0.5,
          );
        }
      }
    }
    final after = count();
    return after > before ? after - before : 0;
  }
}

final _alnumRe = RegExp(r'[\p{L}\p{N}]', unicode: true);
bool _isAlnumRune(int r) => _alnumRe.hasMatch(String.fromCharCode(r));
