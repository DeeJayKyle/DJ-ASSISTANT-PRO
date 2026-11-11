import 'dart:io';

import 'package:path/path.dart' as p;

import 'paths.dart';
import 'serato.dart' show parseSeratoCrate;
import 'serato_cues.dart' show parseSeratoMarkers2Tag;
import 'serato_tags.dart' show readSeratoGeobs;

/// What Serato knows about one music file, found by reading (never writing)
/// Serato's own files: its library list (`_Serato_/database V2`), its crates
/// (`_Serato_/Subcrates/*.crate`), and the cue, loop and beatgrid data Serato
/// keeps inside the file's tags.
class SeratoLink {
  const SeratoLink({
    this.inLibrary = false,
    this.crates = const [],
    this.cues = 0,
    this.loops = 0,
    this.beatgrid = false,
  });
  final bool inLibrary;
  final List<String> crates;
  final int cues, loops;
  final bool beatgrid;

  bool get any => inLibrary || crates.isNotEmpty || hasFileData;
  bool get hasFileData => cues > 0 || loops > 0 || beatgrid;

  /// What a rename or move would do in Serato, in plain words.
  String? moveRisk() {
    if (!inLibrary && crates.isEmpty) {
      return hasFileData
          ? 'Serato data is stored in this file (${_data()}); it moves with the file, but Serato will need to find the file again.'
          : null;
    }
    final where = [
      if (inLibrary) "Serato's library",
      if (crates.isNotEmpty)
        '${crates.length} Serato crate${crates.length == 1 ? '' : 's'} (${crates.take(3).join(', ')}${crates.length > 3 ? '…' : ''})',
    ].join(' and ');
    return 'In $where. Serato will show it as missing until you relocate it (Files → Relocate lost files)'
        '${hasFileData ? '. Its ${_data()} travel inside the file' : ''}.';
  }

  /// What replacing this file with a different one would lose in Serato.
  String? replaceRisk({required bool samePath}) {
    final parts = <String>[];
    if (hasFileData) {
      parts.add(
        "the replacement won't have this file's ${_data()} (they're stored inside the old file, which is kept in Removed files)",
      );
    }
    if ((inLibrary || crates.isNotEmpty) && !samePath) {
      parts.add(
        "Serato's crates point at the old name, so the track will show as missing in Serato",
      );
    }
    if (parts.isEmpty) return null;
    return 'In Serato: ${parts.join('; ')}.';
  }

  String _data() => [
    if (cues > 0) '$cues hot cue${cues == 1 ? '' : 's'}',
    if (loops > 0) '$loops saved loop${loops == 1 ? '' : 's'}',
    if (beatgrid) 'beatgrid',
  ].join(', ');

  Map<String, Object?> toJson() => {
    'in_library': inLibrary,
    'crates': crates,
    'cues': cues,
    'loops': loops,
    'beatgrid': beatgrid,
  };
}

/// Read-only index of Serato's references to files. [seratoDirs] are the
/// `_Serato_` folders to read; by default the one in the Music folder plus one
/// at the top of each drive that a checked file is on.
class SeratoLinks {
  SeratoLinks({List<String>? seratoDirs, this.readFileData = true})
    : _extra = seratoDirs;
  final List<String>? _extra;
  final bool readFileData;

  final _library = <String>{};
  final _crates = <String, List<String>>{};
  final _read = <String>{};

  static String? musicFolderSerato() {
    final env = Platform.environment;
    final home = env['USERPROFILE'] ?? env['HOME'];
    if (home == null || home.isEmpty) return null;
    return p.join(home, 'Music', '_Serato_');
  }

  String _key(String path) => pathKey(p.normalize(path), insensitive: true);

  void _load(String dir) {
    if (!_read.add(_key(dir))) return;
    final root = p.rootPrefix(p.absolute(dir));
    String full(String x) => p.isAbsolute(x) ? x : p.join(root, x);
    try {
      final db = File(p.join(dir, 'database V2'));
      if (db.existsSync() && db.lengthSync() < 512 * 1024 * 1024) {
        for (final x in parseSeratoCrate(db.readAsBytesSync(), tag: 'pfil')) {
          _library.add(_key(full(x)));
        }
      }
      final sub = Directory(p.join(dir, 'Subcrates'));
      if (sub.existsSync()) {
        for (final f in sub.listSync().whereType<File>()) {
          if (!f.path.endsWith('.crate') || f.lengthSync() > 64 * 1024 * 1024) {
            continue;
          }
          final name = p
              .basenameWithoutExtension(f.path)
              .split('%%')
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty)
              .join(' / ');
          for (final x in parseSeratoCrate(f.readAsBytesSync())) {
            (_crates[_key(full(x))] ??= []).add(name);
          }
        }
      }
    } on FileSystemException {
      // Serato's files couldn't be read: treated as no references.
    }
  }

  /// Serato's references to each of [paths] (keys are the paths as given).
  Map<String, SeratoLink> check(Iterable<String> paths) {
    final list = paths.toList();
    for (final d in [
      ...?_extra,
      if (_extra == null) ...[
        ?musicFolderSerato(),
        for (final x in list) p.join(p.rootPrefix(p.absolute(x)), '_Serato_'),
      ],
    ]) {
      if (Directory(d).existsSync()) _load(d);
    }
    final out = <String, SeratoLink>{};
    for (final x in list) {
      final k = _key(x);
      var cues = 0, loops = 0;
      var grid = false;
      if (readFileData) {
        final geob = readSeratoGeobs(x);
        final m = geob['Serato Markers2'];
        if (m != null) {
          final markers = parseSeratoMarkers2Tag(m);
          cues = markers.cues.length;
          loops = markers.loops.length;
        }
        grid = geob.containsKey('Serato BeatGrid');
      }
      out[x] = SeratoLink(
        inLibrary: _library.contains(k),
        crates: List.unmodifiable({...?_crates[k]}),
        cues: cues,
        loops: loops,
        beatgrid: grid,
      );
    }
    return out;
  }
}
