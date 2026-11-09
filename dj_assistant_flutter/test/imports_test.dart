import 'dart:io';

import 'package:dj_assistant/core/catalogue.dart';
import 'package:dj_assistant/core/crates.dart';
import 'package:dj_assistant/core/discovery.dart';
import 'package:dj_assistant/core/gig.dart';
import 'package:dj_assistant/core/json.dart';
import 'package:dj_assistant/core/next_track.dart';
import 'package:dj_assistant/core/rekordbox_import.dart';
import 'package:dj_assistant/core/roots.dart';
import 'package:dj_assistant/core/scanner.dart';
import 'package:dj_assistant/core/serato.dart';
import 'package:dj_assistant/core/sets.dart';
import 'package:dj_assistant/ui/library_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'scanner_test.dart' show copyLibrary, hashes;

/// rekordbox XML, Serato's own play history, playlist files and the
/// library map, against the scanned fixture library.
void main() {
  late Directory music, out;
  late Catalogue cat;
  late Map<String, String> before;
  setUp(() async {
    music = copyLibrary();
    out = Directory(p.join(music.parent.path, 'out'))..createSync();
    cat = Catalogue.open(
      p.join(music.parent.path, 'data', 'catalogue.sqlite3'),
    );
    RootsService(cat).add(music.path);
    await runScan(cat);
    before = hashes(music);
  });
  tearDown(() {
    expect(hashes(music), before, reason: 'music files are only read');
    cat.close();
    music.parent.deleteSync(recursive: true);
  });

  String pathOf(String file) =>
      cat.db.select('SELECT path FROM tracks WHERE file_name=?', [
            file,
          ]).first['path']
          as String;

  test('rekordbox XML playlists become crates of matching tracks', () {
    final deep = pathOf('Deep Tenant - Warehouse 94.mp3').replaceAll('\\', '/');
    final loc =
        'file://localhost${deep.startsWith('/') ? '' : '/'}${Uri.encodeFull(deep)}';
    final xml =
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<DJ_PLAYLISTS Version="1.0.0">\n'
        '  <PRODUCT Name="rekordbox" Version="6.8.0"/>\n'
        '  <COLLECTION Entries="3">\n'
        '    <TRACK TrackID="1" Name="Warehouse 94" Artist="Deep Tenant" Location="$loc">\n'
        '      <POSITION_MARK Name="Drop" Type="0" Start="12.500" Num="0"/>\n'
        '    </TRACK>\n'
        '    <TRACK TrackID="2" Name="Mirrorball" Location="file://localhost/elsewhere/Mirrorball.ogg"/>\n'
        '    <TRACK TrackID="3" Name="Not Here" Artist="Nobody" Location="file://localhost/x/Not%20Here.mp3"/>\n'
        '  </COLLECTION>\n'
        '  <PLAYLISTS>\n'
        '    <NODE Type="0" Name="ROOT" Count="1">\n'
        '      <NODE Type="0" Name="Gigs" Count="1">\n'
        '        <NODE Name="Friday" Type="1" KeyType="0" Entries="3">\n'
        '          <TRACK Key="1"/><TRACK Key="2"/><TRACK Key="3"/>\n'
        '        </NODE>\n'
        '      </NODE>\n'
        '    </NODE>\n'
        '  </PLAYLISTS>\n'
        '</DJ_PLAYLISTS>\n';
    final r = RekordboxImportService(cat).importXml(xml, label: 'test.xml');
    final pl = (r['playlists'] as List).cast<Map>().single;
    expect(pl['playlist'], 'Gigs / Friday');
    expect(pl['matched'], 2, reason: 'by path, and by file name');
    expect(pl['missing'], 1);
    expect(pl['missing_sample'], ['Nobody — Not Here']);
    expect(r['cues'], 1);
    final crates = CratesService(cat);
    final friday = crates.list().firstWhere((c) => c.name == 'Friday');
    expect(crates.count(friday.id), 2);
    RekordboxImportService(cat).importXml(xml, label: 'test.xml');
    expect(
      crates.list().where((c) => c.name == 'Friday').length,
      1,
      reason: 'a second import reuses the crates',
    );
    expect(
      () => RekordboxImportService(cat).importXml('<foo/>'),
      throwsA(isA<RekordboxImportException>()),
    );
    expect(
      rekordboxLocationPath('file://localhost/C:/My%20Music/a%20b.mp3'),
      'C:/My Music/a b.mp3',
    );
    expect(
      rekordboxLocationPath('file://localhost/Users/k/a%26b.mp3'),
      '/Users/k/a&b.mp3',
    );
  });

  test("Serato's own play history is read from a copy, once", () {
    final path = p.join(out.path, 'master.sqlite');
    final db = sqlite3.open(path);
    db.execute(
      'CREATE TABLE history_session(id INTEGER PRIMARY KEY, start_time INTEGER, end_time INTEGER)',
    );
    db.execute(
      'CREATE TABLE history_entry(id INTEGER PRIMARY KEY, session_id INTEGER, deck INTEGER, played INTEGER, '
      'start_time INTEGER, end_time INTEGER, length_ms INTEGER, portable_id TEXT, file_name TEXT, '
      'artist TEXT, name TEXT, bpm REAL)',
    );
    db.execute(
      'INSERT INTO history_session VALUES (7, 1762300000, 1762310000)',
    );
    db.execute(
      'INSERT INTO history_entry(session_id, played, start_time, file_name, artist, name) VALUES '
      "(7, 1, 1762300100, '/Volumes/USB/Deep Tenant - Warehouse 94.mp3', 'Deep Tenant', 'Warehouse 94'), "
      "(7, 0, 1762300200, '/x/skipped.mp3', 'A', 'Loaded but not played'), "
      "(7, 1, 1762300300, '/x/unknown.mp3', 'Nobody', 'Unknown')",
    );
    db.close();
    final original = File(path).readAsBytesSync();
    final serato = SeratoService(cat);
    expect(serato.importSeratoDbHistory(path), {
      'sessions': 1,
      'skipped': 0,
      'matched': 1,
      'unmatched': 1,
    });
    expect(serato.importSeratoDbHistory(path)['skipped'], 1);
    expect(serato.history().length, 2);
    expect(
      File(path).readAsBytesSync(),
      original,
      reason: 'only a copy is read',
    );
    expect(
      cat.db
          .select(
            "SELECT played_at FROM play_history WHERE source='serato' AND title='Warehouse 94'",
          )
          .first['played_at'],
      1762300100000,
    );
    final bad = File(p.join(out.path, 'other.sqlite'));
    sqlite3.open(bad.path)
      ..execute('CREATE TABLE x(a)')
      ..close();
    expect(
      () => serato.importSeratoDbHistory(bad.path),
      throwsA(isA<SeratoException>()),
    );
  });

  test('playlist files match by path, then by artist and title', () {
    final deep = pathOf('Deep Tenant - Warehouse 94.mp3');
    final m3u =
        '#EXTM3U\n#EXTINF:300,Someone - Renamed\n$deep\n'
        '#EXTINF:200,Nobody - Missing Song\n/x/missing.mp3\n';
    final r = DiscoveryService(cat).matchPlaylistFile(m3u);
    expect(r['owned'], 1);
    expect(r['missing'], 1);
    final lines = (r['lines'] as List).cast<Map>();
    expect([for (final l in lines) l['line']], [1, 2]);
    final csv = DiscoveryService.shoppingListCsv(r);
    expect(csv, startsWith('Status,Artist,Title,Beatport'));
    expect(
      csv,
      contains(
        '"Missing","Nobody","Missing Song","https://www.beatport.com/search?q=Nobody+Missing+Song"',
      ),
    );
    expect(
      playlistFileEntries('Artist,Title\nA,"One, Two"\n').single.display,
      'A - One, Two',
    );
    expect(playlistFileEntries('X - Y\n').single.display, 'X - Y');
  });

  test('library map places tracks by tempo and energy', () {
    final pts = mapPoints(const [
      NextTrackCandidate(id: 1, bpm: 120, energy: 1),
      NextTrackCandidate(id: 2, bpm: 62, energy: 10),
      NextTrackCandidate(id: 3, bpm: 87, energy: 5), // doubled? no: in range
      NextTrackCandidate(id: 4, bpm: 45, energy: 5), // half time → 90
      NextTrackCandidate(id: 5, bpm: 240, energy: 5), // → 120
      NextTrackCandidate(id: 6, energy: 5), // no BPM: not drawn
    ]);
    expect(pts.map((p) => p.c.id), [1, 2, 3, 4, 5]);
    expect(pts[0].x, closeTo(0.5, 0.01));
    expect(pts[0].y, closeTo(0, 0.04));
    expect(pts[1].y, closeTo(1, 0.04));
    expect(pts[3].x, closeTo(0.25, 0.01));
    expect(pts[4].x, closeTo(0.5, 0.01));
    expect(keyColor('8A'), isNot(keyColor('8B')));
    expect(keyColor('nonsense'), keyColor(null));
  });

  test('set plans open with the chosen track and carry grades', () {
    final open =
        cat.db
                .select(
                  "SELECT id FROM tracks WHERE file_name='Mirrorball.ogg'",
                )
                .first['id']
            as int;
    final plan = SetsService(cat).plan(
      setParamsFromJson({
        'duration_min': 30,
        'opening_track_id': open,
        'key_mode': 'off',
        'min_track_seconds': 0,
      }),
    );
    final slots = (plan['slots'] as List).cast<Map>();
    expect(slots.first['track_id'], open);
    expect(slots.first['grade'], isNull);
    expect(slots.skip(1).every((x) => x.containsKey('grade')), isTrue);
    expect(slots.every((x) => x['issues'] is List), isTrue);
    expect((plan['params'] as Map)['key_mode'], 'off');
  });

  test('gig mode follows Serato: new plays are logged once, in order', () {
    final path = p.join(out.path, 'master.sqlite');
    final db = sqlite3.open(path);
    db.execute(
      'CREATE TABLE history_entry(id INTEGER PRIMARY KEY, session_id INTEGER, played INTEGER, '
      'start_time INTEGER, file_name TEXT, artist TEXT, name TEXT)',
    );
    final gig = GigService(cat);
    gig.start('Friday');
    final startedSec =
        (cat.db.select('SELECT started_at FROM gigs').first['started_at']
            as int) ~/
        1000;
    db.execute(
      'INSERT INTO history_entry(session_id, played, start_time, file_name, artist, name) VALUES '
      "(1, 1, ${startedSec - 600}, '/old.mp3', 'Before', 'The gig'), "
      "(1, 1, ${startedSec + 5}, '/USB/Mirrorball.ogg', '', 'Mirrorball'), "
      "(1, 0, ${startedSec + 6}, '/x.mp3', 'Loaded', 'Only')",
    );
    expect(gig.followSerato(path).length, 1);
    expect(gig.followSerato(path), isEmpty, reason: 'nothing new');
    db.execute(
      'INSERT INTO history_entry(session_id, played, start_time, file_name, artist, name) VALUES '
      "(1, 1, ${startedSec + 300}, '/USB/Deep Tenant - Warehouse 94.mp3', 'Deep Tenant', 'Warehouse 94')",
    );
    db.close();
    expect(gig.followSerato(path).length, 1);
    final played = [
      for (final e in (gig.current()!['events'] as List).cast<Map>())
        if (e['kind'] == 'played') e['track'],
    ];
    expect(played.length, 2);
    expect('${played.last}', contains('Warehouse 94'));
    gig.end();
    expect(gig.followSerato(path), isEmpty, reason: 'only during a gig');
  });
}
