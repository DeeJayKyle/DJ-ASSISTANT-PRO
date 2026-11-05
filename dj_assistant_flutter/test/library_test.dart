import 'package:dj_assistant/core/catalogue.dart';
import 'package:dj_assistant/core/library.dart';
import 'package:dj_assistant/core/text.dart';
import 'package:flutter_test/flutter_test.dart';

/// Adds a catalogued track the way the scanner does (search_text = folded tags + path).
int addTrack(
  Catalogue c,
  String file, {
  String? title,
  String? artist,
  String? genre,
  double? bpm,
  String? key,
  int? kbps,
  bool lossless = false,
  String presence = 'present',
}) {
  c.db.execute(
    "INSERT OR IGNORE INTO library_roots(id, path, path_key, status, added_at) VALUES (1, '/music', '/music', 'online', 0)",
  );
  final st = fold([title, artist, genre, file].whereType<String>().join(' '));
  c.db.execute(
    "INSERT INTO tracks(uid, root_id, path, path_key, rel_path, file_name, extension, file_size, read_status, presence, title, artist, genre, bpm_tag, key_tag, bitrate_kbps, lossless, format, search_text, first_seen_at, last_seen_at, media_kind) "
    "VALUES (?, 1, ?, ?, ?, ?, 'mp3', 1000, 'ok', ?, ?, ?, ?, ?, ?, ?, ?, 'MP3', ?, 0, 0, 'audio')",
    [
      'uid-$file',
      '/music/$file',
      '/music/$file',
      file,
      file,
      presence,
      title,
      artist,
      genre,
      bpm,
      key,
      kbps,
      lossless ? 1 : 0,
      st,
    ],
  );
  return c.db.lastInsertRowId;
}

void main() {
  late Catalogue c;
  late LibraryService lib;
  setUp(() {
    c = Catalogue.inMemory();
    lib = LibraryService(c);
    addTrack(
      c,
      'essence.mp3',
      title: 'Essence',
      artist: 'Wizkid',
      genre: 'Afrobeats',
      bpm: 104,
      key: 'Am',
      kbps: 320,
    );
    addTrack(
      c,
      'halo.mp3',
      title: 'Halo',
      artist: 'Beyoncé',
      genre: 'Pop',
      bpm: 80,
      key: '8B',
      kbps: 96,
    );
    addTrack(
      c,
      'gone.mp3',
      title: 'Gone',
      artist: 'Ghost',
      presence: 'missing',
    );
  });
  tearDown(() => c.close());

  test('search is accent-insensitive, multi-word, and hides missing files', () {
    expect(
      lib.search(const TrackQuery(text: 'beyonce')).rows.single.title,
      'Halo',
    );
    expect(
      lib.search(const TrackQuery(text: 'WIZKID afro')).rows.single.title,
      'Essence',
    );
    expect(lib.search(const TrackQuery(text: 'wizkid pop')).total, 0);
    expect(lib.search(const TrackQuery()).total, 2);
    expect(lib.search(const TrackQuery(includeMissing: true)).total, 3);
    expect(
      lib.search(const TrackQuery(text: '100%')).total,
      0,
      reason: 'LIKE wildcards are escaped',
    );
  });

  test('values come from the DJ first, then the tag; keys are normalised to Camelot', () {
    final essence = lib.search(const TrackQuery(text: 'essence')).rows.single;
    expect(essence.key, '8A');
    expect(essence.keySource, 'tag');
    expect(essence.bpm, 104);
    c.db.execute(
      'INSERT INTO track_user(track_id, bpm, genre, updated_at) VALUES (?, 105.5, ?, 0)',
      [essence.id, 'Afro House'],
    );
    final edited = lib.search(const TrackQuery(text: 'essence')).rows.single;
    expect(edited.bpm, 105.5);
    expect(edited.bpmSource, 'you');
    expect(edited.genre, 'Afro House');
    expect(
      lib.search(const TrackQuery(text: 'afro house')).total,
      1,
      reason: 'own edits are searchable',
    );
  });

  test('quality follows the low-bitrate setting; sorting works both ways', () {
    final rows = lib.search(const TrackQuery(sort: 'bpm')).rows;
    expect(rows.map((r) => r.title), ['Halo', 'Essence']);
    expect(
      lib.search(const TrackQuery(sort: 'bpm', desc: true)).rows.first.title,
      'Essence',
    );
    expect(rows.first.quality, 'low_bitrate');
    c.setSetting('low_bitrate_kbps', '64');
    expect(
      lib.search(const TrackQuery(text: 'halo')).rows.single.quality,
      'lossy',
    );
    expect(
      () => lib.search(const TrackQuery(sort: 'drop table')),
      throwsArgumentError,
    );
  });
}
