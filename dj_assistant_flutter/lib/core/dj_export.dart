import 'catalogue.dart';
import 'crates.dart';
import 'library.dart';
import 'library_edit.dart';
import 'serato_library.dart';

/// Crates built in DJ Assistant, saved into Serato: one `.crate` file per
/// crate in `_Serato_/Subcrates`, nested with "%%" like Serato's own. A
/// Serato crate with the same name is replaced (its columns and sort order
/// are kept), so building a crate again updates it in Serato.
class DjExportException implements Exception {
  DjExportException(this.message);
  final String message;
  @override
  String toString() => message;
}


class _Node {
  _Node(this.id, this.name, this.parent);
  final int id;
  final String name;
  final int? parent;
}

class DjExportService {
  DjExportService(this.cat);
  final Catalogue cat;

  List<_Node> _all() => [
    for (final r in cat.db.select(
      'SELECT id, name, parent_id FROM crates ORDER BY sort_order, id',
    ))
      _Node(r['id'] as int, r['name'] as String, r['parent_id'] as int?),
  ];

  List<int> _members(int crateId) => LibraryService(cat)
      .trackIds(TrackQuery(extraWhere: CratesService(cat).membership(crateId)));

  /// The chosen crates plus everything nested inside them.
  List<int> _selection(List<_Node> all, List<int>? ids) {
    if (ids == null) return [for (final c in all) c.id];
    final out = [...ids];
    for (var i = 0; i < out.length; i++) {
      for (final c in all.where((c) => c.parent == out[i])) {
        if (!out.contains(c.id)) out.add(c.id);
      }
    }
    return out;
  }

  List<String> _chain(List<_Node> all, int id) {
    final names = <String>[];
    _Node? cur = all.where((c) => c.id == id).firstOrNull;
    var guard = 0;
    while (cur != null && guard++ <= 32) {
      names.add(cur.name);
      final parent = cur.parent;
      cur = parent == null
          ? null
          : all.where((x) => x.id == parent).firstOrNull;
    }
    return names.reversed.toList();
  }

  /// Saves the chosen crates (all when null) into [lib]. Crates that only
  /// group sub-crates are created empty so Serato shows the nesting.
  Map<String, Object?> saveToSerato(SeratoLibrary lib, {List<int>? crateIds}) {
    final all = _all();
    final written = <Map<String, Object?>>[];
    var other = 0;
    for (final id in _selection(all, crateIds)) {
      final c = all.firstWhere((c) => c.id == id);
      final paths = [
        for (final tid in _members(id))
          for (final r in cat.db.select(
            "SELECT path FROM tracks WHERE id=? AND presence='present'",
            [tid],
          ))
            r['path'] as String,
      ];
      final name = _chain(all, id).map(crateFileName).join('%%');
      final (n, o) = lib.save(name, paths);
      other += o;
      written.add({'crate': c.name, 'serato': name, 'tracks': n});
    }
    return {
      'written': written,
      'skipped_other_drive': other,
      'note': other == 0
          ? 'Start Serato to see the crates.'
          : "$other track(s) are on another drive; they belong in that drive's own _Serato_ folder.",
    };
  }
}
