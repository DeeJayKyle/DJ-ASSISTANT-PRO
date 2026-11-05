import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import 'blake3.dart';
import 'catalogue.dart';
import 'jobs.dart';
import 'paths.dart';
import 'roots.dart';
import 'text.dart';

class DocsException implements Exception {
  DocsException(this.message);
  final String message;
  @override
  String toString() => message;
}

const _textExt = {
  'txt',
  'md',
  'csv',
  'tsv',
  'json',
  'xml',
  'html',
  'htm',
  'log',
  'ini',
  'yaml',
  'yml',
  'srt',
  'cue',
  'm3u',
  'm3u8',
  'nfo',
};
const _maxText = 200000;

/// Personal files (1.x `docs.rs`): opt-in and separate from music. Indexes
/// only folders the DJ adds, reads files without changing them, and never
/// feeds music recommendations.
class PersonalFiles {
  PersonalFiles(this.cat);
  final Catalogue cat;

  bool get enabled => cat.getSetting('docs_enabled') == '1';

  void _require() {
    if (!enabled) {
      throw DocsException(
        'The personal files module is turned off. Turn it on in Settings first.',
      );
    }
  }

  List<Map<String, Object?>> roots() => [
    for (final r in cat.db.select(
      'SELECT r.id, r.path, r.status, r.last_scan_at, '
      "(SELECT COUNT(*) FROM documents d WHERE d.root_id=r.id AND d.presence='present') AS count "
      'FROM doc_roots r ORDER BY r.path',
    ))
      Map.of(r),
  ];

  void addRoot(String path) {
    _require();
    final t = path.trim();
    if (!p.isAbsolute(t) || !Directory(t).existsSync()) {
      throw DocsException('choose an existing folder');
    }
    final key = pathKey(t, insensitive: true);
    for (final r in RootsService(cat).list()) {
      if (keyIsWithin(key, pathKey(r.path, insensitive: true))) {
        throw DocsException(
          'that folder is inside your music library; personal files are kept separate',
        );
      }
    }
    cat.db.execute(
      "INSERT OR IGNORE INTO doc_roots(path, path_key, status, added_at) VALUES (?,?,'unknown',?)",
      [t, key, nowMs()],
    );
  }

  void removeRoot(int id) =>
      cat.db.execute('DELETE FROM doc_roots WHERE id=?', [id]);

  /// Indexes every root (runs inside a job; see [docsScanJob]).
  Future<void> scan(JobProgress prog) async {
    _require();
    final start = nowMs();
    for (final r in cat.db.select('SELECT id, path FROM doc_roots')) {
      final rid = r['id'] as int, rpath = r['path'] as String;
      final root = Directory(rpath);
      if (!root.existsSync()) {
        cat.db.execute("UPDATE doc_roots SET status='offline' WHERE id=?", [
          rid,
        ]);
        continue;
      }
      cat.db.execute("UPDATE doc_roots SET status='online' WHERE id=?", [rid]);
      await for (final e in root.list(recursive: true, followLinks: false)) {
        if (await prog.checkpoint()) return;
        if (e is! File) continue;
        final name = p.basename(e.path);
        if (name.startsWith(r'~$') || name.startsWith('._')) continue;
        final ext = p.extension(name).replaceFirst('.', '').toLowerCase();
        final FileStat st;
        try {
          st = e.statSync();
        } on FileSystemException {
          continue;
        }
        final mtime = st.modified.millisecondsSinceEpoch;
        final key = pathKey(e.path, insensitive: true);
        if (cat.db.select(
          'SELECT 1 FROM documents WHERE path_key=? AND size=? AND mtime IS ?',
          [key, st.size, mtime],
        ).isNotEmpty) {
          cat.db.execute(
            "UPDATE documents SET presence='present', last_seen_at=? WHERE path_key=?",
            [nowMs(), key],
          );
          prog.tick();
          continue;
        }
        final (status, text) = extractDocText(e.path, ext, st.size);
        final rel = p.relative(p.dirname(e.path), from: rpath);
        final folder = rel == '.' ? '' : rel;
        cat.db.execute(
          'INSERT INTO documents(root_id, path, path_key, name, folder, ext, size, mtime, content_status, content, search_text, hash, presence, last_seen_at) '
          "VALUES (?,?,?,?,?,?,?,?,?,?,?,NULL,'present',?) "
          'ON CONFLICT(path_key) DO UPDATE SET size=excluded.size, mtime=excluded.mtime, content_status=excluded.content_status, content=excluded.content, '
          "search_text=excluded.search_text, hash=NULL, presence='present', last_seen_at=excluded.last_seen_at",
          [
            rid,
            e.path,
            key,
            name,
            folder,
            ext,
            st.size,
            mtime,
            status,
            text,
            fold('$name $folder ${text ?? ''}'),
            nowMs(),
          ],
        );
        prog.tick(ok: status != 'unreadable');
      }
      cat.db.execute(
        "UPDATE documents SET presence='missing' WHERE root_id=? AND last_seen_at < ?",
        [rid, start],
      );
      cat.db.execute('UPDATE doc_roots SET last_scan_at=? WHERE id=?', [
        nowMs(),
        rid,
      ]);
    }
    // Hash same-size files to confirm duplicates.
    for (final r in cat.db.select(
      "SELECT id, path FROM documents WHERE presence='present' AND hash IS NULL AND size > 0 "
      "AND size IN (SELECT size FROM documents WHERE presence='present' GROUP BY size HAVING COUNT(*)>1)",
    )) {
      if (await prog.checkpoint()) break;
      final h = blake3File(r['path'] as String);
      if (h != null) {
        cat.db.execute('UPDATE documents SET hash=? WHERE id=?', [h, r['id']]);
      }
    }
  }

  List<Map<String, Object?>> search(
    String text, {
    String? ext,
    int limit = 200,
  }) {
    _require();
    var sql =
        'SELECT id, path, name, folder, ext, size, mtime, content_status, content '
        "FROM documents WHERE presence='present'";
    final ps = <Object?>[];
    final toks = text
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .take(10)
        .map(fold)
        .toList();
    for (final t in toks) {
      ps.add('%${likeEscape(t)}%');
      sql += r" AND search_text LIKE ? ESCAPE '\'";
    }
    if (ext != null && ext.isNotEmpty) {
      ps.add(ext.toLowerCase());
      sql += ' AND ext = ?';
    }
    sql += ' ORDER BY mtime DESC LIMIT ${limit.clamp(1, 1000)}';
    final q = toks.firstOrNull;
    return [
      for (final r in cat.db.select(sql, ps))
        {
          for (final k in [
            'id',
            'path',
            'name',
            'folder',
            'ext',
            'size',
            'mtime',
            'content_status',
          ])
            k: r[k],
          'snippet': () {
            final c = r['content'] as String?;
            if (c == null || q == null) return null;
            final f = fold(c);
            final i = f.indexOf(q);
            if (i < 0) return null;
            final start = i - 60 < 0 ? 0 : i - 60;
            final s = f.substring(start);
            return s.length > 180 ? s.substring(0, 180) : s;
          }(),
        },
    ];
  }

  Map<String, Object?> report() {
    _require();
    List<Map<String, Object?>> q(String sql) => [
      for (final r in cat.db.select(sql)) Map.of(r),
    ];
    final sugg = <String, List<String>>{};
    for (final r in cat.db.select(
      "SELECT path, ext, mtime FROM documents WHERE presence='present' AND folder='' LIMIT 2000",
    )) {
      final m = r['mtime'] as int?;
      final year = m == null ? 0 : 1970 + m ~/ 31556952000;
      final kind = switch (r['ext']) {
        'pdf' ||
        'doc' ||
        'docx' ||
        'odt' ||
        'txt' ||
        'md' ||
        'rtf' => 'Documents',
        'xls' || 'xlsx' || 'csv' || 'ods' => 'Spreadsheets',
        'jpg' || 'jpeg' || 'png' || 'gif' || 'heic' || 'webp' => 'Pictures',
        'zip' || 'rar' || '7z' => 'Archives',
        _ => 'Other',
      };
      sugg.putIfAbsent('$kind/$year', () => []).add(r['path'] as String);
    }
    final keys = sugg.keys.toList()..sort();
    return {
      'statuses': q(
        "SELECT content_status AS status, COUNT(*) AS count FROM documents WHERE presence='present' GROUP BY content_status",
      ),
      'duplicates': [
        for (final r in cat.db.select(
          "SELECT GROUP_CONCAT(path, char(31)) AS paths, MAX(size) AS size FROM documents WHERE presence='present' AND hash IS NOT NULL GROUP BY hash HAVING COUNT(*)>1 LIMIT 500",
        ))
          {'paths': (r['paths'] as String).split('\u001f'), 'size': r['size']},
      ],
      'types': q(
        "SELECT ext, COUNT(*) AS count, SUM(size) AS bytes FROM documents WHERE presence='present' GROUP BY ext ORDER BY COUNT(*) DESC LIMIT 30",
      ),
      'flagged': q(
        "SELECT path, content_status AS status FROM documents WHERE presence='present' AND content_status IN ('encrypted','unreadable') ORDER BY path LIMIT 300",
      ),
      'suggestions': [
        for (final k in keys)
          if (sugg[k]!.length >= 3)
            {
              'folder': k,
              'count': sugg[k]!.length,
              'examples': sugg[k]!.take(3).toList(),
              'note': 'Suggestion only — nothing is moved.',
            },
      ],
    };
  }

  void clear() {
    cat.db.execute('DELETE FROM documents');
    cat.db.execute('DELETE FROM doc_roots');
  }
}

/// The personal-files scan as a background job.
JobBody docsScanJob(String dbPath) => (ctx) async {
  final c = Catalogue.open(dbPath);
  try {
    await PersonalFiles(c).scan(ctx);
  } finally {
    c.close();
  }
};

/// A document's text where supported: (status, text).
(String, String?) extractDocText(String path, String ext, int size) {
  if (_textExt.contains(ext)) {
    if (size > 20000000) return ('too_large', null);
    try {
      final raf = File(path).openSync();
      try {
        return (
          'indexed',
          utf8.decode(raf.readSync(_maxText), allowMalformed: true),
        );
      } finally {
        raf.closeSync();
      }
    } on FileSystemException {
      return ('unreadable', null);
    }
  }
  List<int> head(int n) {
    try {
      final raf = File(path).openSync();
      try {
        return raf.readSync(n);
      } finally {
        raf.closeSync();
      }
    } on FileSystemException {
      return const [];
    }
  }

  if (ext == 'docx' || ext == 'odt') {
    // Encrypted Office files are OLE containers, not zip archives.
    const ole = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1];
    final h = head(8);
    if (h.length == 8 &&
        [for (var i = 0; i < 8; i++) h[i] == ole[i]].every((x) => x)) {
      return ('encrypted', null);
    }
    InputFileStream? input;
    try {
      // Closed in `finally`: an open handle would lock the DJ's document.
      input = InputFileStream(path);
      final z = ZipDecoder().decodeStream(input);
      final entry =
          z.findFile('word/document.xml') ?? z.findFile('content.xml');
      if (entry == null) return ('not_supported', null);
      final raw = entry.readBytes();
      if (raw == null) return ('unreadable', null);
      final xml = utf8.decode(
        raw.length > 4000000 ? raw.sublist(0, 4000000) : raw,
        allowMalformed: true,
      );
      final out = StringBuffer();
      var inTag = false;
      for (final c in xml.split('')) {
        if (c == '<') {
          inTag = true;
        } else if (c == '>') {
          inTag = false;
          out.write(' ');
        } else if (!inTag) {
          out.write(c);
        }
        if (out.length > _maxText) break;
      }
      return (
        'indexed',
        out
            .toString()
            .split(RegExp(r'\s+'))
            .where((w) => w.isNotEmpty)
            .join(' '),
      );
    } on Exception {
      return ('unreadable', null);
    } finally {
      input?.closeSync();
    }
  }
  if (ext == 'pdf') {
    return latin1.decode(head(2048)).contains('/Encrypt')
        ? ('encrypted', null)
        : ('name_only', null);
  }
  if (ext == 'zip') {
    final enc = zipEncrypted(path);
    return enc == null
        ? ('unreadable', null)
        : (enc ? 'encrypted' : 'name_only', null);
  }
  return ('name_only', null);
}

/// Whether any of the first 50 entries of a ZIP is encrypted (general-purpose
/// flag bit 0 in the central directory), or null when it is not a ZIP.
bool? zipEncrypted(String path) {
  try {
    final raf = File(path).openSync();
    try {
      final len = raf.lengthSync();
      final tail = len < 65557 ? len : 65557;
      raf.setPositionSync(len - tail);
      final b = raf.readSync(tail);
      var eocd = -1;
      for (var i = b.length - 22; i >= 0; i--) {
        if (b[i] == 0x50 &&
            b[i + 1] == 0x4b &&
            b[i + 2] == 5 &&
            b[i + 3] == 6) {
          eocd = i;
          break;
        }
      }
      if (eocd < 0) return null;
      int u16(List<int> x, int o) => x[o] | x[o + 1] << 8;
      int u32(List<int> x, int o) => u16(x, o) | u16(x, o + 2) << 16;
      final count = u16(b, eocd + 10);
      final size = u32(b, eocd + 12), offset = u32(b, eocd + 16);
      if (offset + size > len) return null;
      raf.setPositionSync(offset);
      final cd = raf.readSync(size);
      var o = 0;
      for (var n = 0; n < count && n < 50 && o + 46 <= cd.length; n++) {
        if (u32(cd, o) != 0x02014b50) return null;
        if (u16(cd, o + 8) & 1 == 1) return true;
        o += 46 + u16(cd, o + 28) + u16(cd, o + 30) + u16(cd, o + 32);
      }
      return false;
    } finally {
      raf.closeSync();
    }
  } on FileSystemException {
    return null;
  }
}
