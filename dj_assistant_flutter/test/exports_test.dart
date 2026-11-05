import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:dj_assistant/core/catalogue.dart';
import 'package:dj_assistant/core/crates.dart';
import 'package:dj_assistant/core/dj_export.dart';
import 'package:dj_assistant/core/export.dart';
import 'package:dj_assistant/core/gigpack.dart';
import 'package:dj_assistant/core/library.dart';
import 'package:dj_assistant/core/library_edit.dart';
import 'package:dj_assistant/core/roots.dart';
import 'package:dj_assistant/core/scanner.dart';
import 'package:dj_assistant/core/serato.dart';
import 'package:dj_assistant/core/tag_writer.dart';
import 'package:dj_assistant/core/templates.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'scanner_test.dart' show copyLibrary, hashes;

/// Ports of 1.x `crate_templates_labels_and_hygiene`, `exports_write_only_the_chosen_file`,
/// `gig_pack_copies_verifies_and_never_overwrites` and
/// `crates_export_to_serato_rekordbox_and_folders`.
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
    cat.close();
    music.parent.deleteSync(recursive: true);
  });

  int idOf(String f) =>
      cat.db.select('SELECT id FROM tracks WHERE file_name=?', [f]).first['id']
          as int;
  List<int> search(String text) =>
      LibraryService(cat).trackIds(TrackQuery(text: text));

  test('crate templates, labels, colour by energy and hygiene', () {
    final t = TemplatesService(cat);
    expect(t.apply('energy')['created'], 5);
    expect(t.apply('energy')['created'], 0, reason: 'templates are idempotent');
    expect(t.apply('genre_by_energy', genre: 'Afrobeats')['created'], 5);
    expect(() => t.apply('genre_by_energy'), throwsA(isA<TemplateException>()));
    for (final id in ['genres', 'utility', 'events', 'ratings', 'decades']) {
      expect(t.apply(id)['created'] as int, greaterThan(0), reason: id);
    }
    final crates = CratesService(cat).list();
    final energy = crates.firstWhere((c) => c.name == 'Energy');
    expect(crates.where((c) => c.parentId == energy.id).length, 5);
    expect((t.labels()['rating'] as Map)['5'], 'Guaranteed');
    expect((t.labels()['color'] as Map)['red'], 'Peak time');
    final id = idOf('Deep Tenant - Warehouse 94.mp3');
    LibraryService(cat).updateUserFields([id], {'energy': 9});
    t.colourByEnergy();
    expect(LibraryService(cat).row(id)!.color, 'red');
    CratesService(cat).create(const CrateInput(name: 'Misc', kind: 'manual'));
    expect(
      (t.hygiene()['issues'] as List).any((i) => (i as Map)['crate'] == 'Misc'),
      isTrue,
    );
    expect(crateTemplates().length, 7);
  });

  test('exports write only the chosen file', () {
    final ex = ExportService(cat);
    final m3u = p.join(out.path, 'set.m3u8');
    expect(ex.writeM3u(search('sunrise'), m3u), 5);
    final text = File(m3u).readAsStringSync();
    expect(text, startsWith('#EXTM3U'));
    expect(
      text,
      contains('#EXTINF:2,Lagos Lights - Sunrise Groove (feat. Ada)'),
    );
    expect(
      () => ex.writeM3u(search('sunrise'), m3u),
      throwsA(isA<ExportException>()),
      reason: 'no silent overwrite',
    );
    final csv = p.join(out.path, 'list.csv');
    ex.writeCsv(LibraryService(cat).trackIds(const TrackQuery()), csv);
    expect(File(csv).readAsLinesSync().length, 23);
    expect(
      () => ex.writeM3u([1], p.join(out.path, 'x.mp3')),
      throwsA(isA<ExportException>()),
    );
    expect(hashes(music), before);
  });

  test('gig pack copies, verifies, reports and never overwrites', () async {
    final packs = GigPackService(cat);
    expect(
      () => packs.preview(search('sunrise'), p.join(music.path, 'House'), 'x'),
      throwsA(isA<GigPackException>()),
    );
    final ids = [...search('sunrise'), idOf('corrupt.mp3')];
    File(p.join(music.path, 'House', 'Mirrorball.ogg')).deleteSync();
    ids.add(idOf('Mirrorball.ogg'));
    final plan = packs.preview(ids, out.path, 'Sat: Club/Night');
    expect(plan.missing, 1);
    expect(plan.packDir, endsWith('Sat_ Club_Night'));
    final r = await packs.execute(plan);
    expect(r['failed'], 0);
    final manifest = jsonDecode(
      File(p.join(plan.packDir, 'manifest.json')).readAsStringSync(),
    ) as Map;
    expect((manifest['files'] as List).length, 6);
    expect(
      (manifest['files'] as List).every((f) => (f as Map)['verified'] == true),
      isTrue,
    );
    expect(
      File(p.join(plan.packDir, 'missing-and-failed.txt')).readAsStringSync(),
      contains('Mirrorball.ogg'),
    );
    expect(
      File(p.join(plan.packDir, 'Music', 'Sunrise Groove (copy).mp3'))
          .existsSync(),
      isTrue,
    );
    expect(File(p.join(plan.packDir, 'playlist.m3u8')).existsSync(), isTrue);
    final again = packs.preview([ids.first], out.path, 'Sat: Club/Night');
    await expectLater(packs.execute(again), throwsA(isA<GigPackException>()));
    before.removeWhere((k, _) => k.endsWith('Mirrorball.ogg'));
    expect(
      hashes(music),
      before,
      reason: 'a gig pack never changes a source file',
    );
  });

  test('a ZIP pack with a layout and clean tags on the copies only', () async {
    final a = idOf('Lagos Lights - Sunrise Groove.mp3'),
        b = idOf('Low Tide.flac');
    LibraryService(cat)
        .updateUserFields([a], {'genre': 'Afro House', 'bpm': 104});
    final plan = GigPackService(cat).preview(
      [],
      out.path,
      'Friday',
      opts: PackOptions(
        items: [
          PackItem(
            a,
            folder: 'Afro/Warm Up',
            name: 'Lagos Lights - Sunrise Groove',
          ),
          PackItem(b, folder: 'Chill'),
        ],
        playlists: [
          PackPlaylist('Warm up', 'Afro/Warm Up', [a]),
          PackPlaylist('All', 'All', [a, b]),
        ],
        zip: true,
        writeTags: true,
      ),
    );
    expect(plan.packDir, endsWith('Friday.zip'));
    final r = await GigPackService(cat).execute(plan);
    expect(r['tagged'], 2);
    final zip = ZipDecoder().decodeBytes(File(plan.packDir).readAsBytesSync());
    final names = [for (final f in zip.files) f.name];
    expect(
      names,
      containsAll([
        'Afro/Warm Up/Lagos Lights - Sunrise Groove.mp3',
        'Chill/Low Tide.flac',
        'Afro/Warm Up.m3u8',
        'All.m3u8',
        'manifest.json',
      ]),
    );
    final copy = File(p.join(out.path, 'tagged.mp3'))
      ..writeAsBytesSync(
        zip
            .findFile('Afro/Warm Up/Lagos Lights - Sunrise Groove.mp3')!
            .readBytes()!,
      );
    expect(readWritableTags(copy.path, 'mp3')['genre'], 'Afro House');
    expect(readWritableTags(copy.path, 'mp3')['bpm'], '104');
    expect(
      utf8.decode(zip.findFile('Afro/Warm Up.m3u8')!.readBytes()!),
      contains(
        'Warm Up${Platform.pathSeparator}Lagos Lights - Sunrise Groove.mp3',
      ),
    );
    expect(
      Directory('${plan.packDir}.tmp').existsSync(),
      isFalse,
      reason: 'the staging folder is removed',
    );
    expect(hashes(music), before, reason: 'originals are never tagged');
  });

  test('crates export to Serato, rekordbox and folders', () async {
    final crates = CratesService(cat);
    final folder = crates.create(
      const CrateInput(name: 'Gigs', kind: 'manual'),
    );
    final wed = crates.create(
      CrateInput(name: 'Wedding & Party', kind: 'manual', parentId: folder.id),
    );
    final a = idOf('Deep Tenant - Warehouse 94.mp3'),
        b = idOf('Mirrorball.ogg');
    crates.addTracks(wed.id, [a, b]);
    final afro = crates.create(
      const CrateInput(
        name: 'Afro',
        kind: 'smart',
        rules: {
          'match': 'all',
          'rules': [
            {
              'kind': 'condition',
              'field': 'genre',
              'op': 'equals',
              'value': 'Afrobeats',
            },
          ],
        },
      ),
    );
    final afroN = crates.count(afro.id);
    final dj = DjExportService(cat);

    // Serato: new crate files, nested with %%, never overwriting.
    final serato = p.join(music.path, '_Serato_');
    Directory(p.join(serato, 'Subcrates')).createSync(recursive: true);
    File(p.join(serato, 'Subcrates', 'Afro.crate'))
        .writeAsStringSync('existing');
    expect(() => dj.exportSerato(out.path), throwsA(isA<DjExportException>()));
    dj.exportSerato(serato, crateIds: [folder.id, afro.id]);
    final sub = p.join(serato, 'Subcrates');
    expect(
      File(p.join(sub, 'Gigs%%Wedding & Party.crate')).existsSync(),
      isTrue,
    );
    expect(File(p.join(sub, 'Afro.crate')).readAsStringSync(), 'existing');
    expect(File(p.join(sub, 'Afro (DJ Assistant).crate')).existsSync(), isTrue);
    final paths = parseSeratoCrate(
      File(p.join(sub, 'Gigs%%Wedding & Party.crate')).readAsBytesSync(),
    );
    expect(paths.length, 2);
    expect(
      paths.every(
        (x) => !x.startsWith('/') && (x.endsWith('.mp3') || x.endsWith('.ogg')),
      ),
      isTrue,
    );
    File(p.join(sub, 'Afro.crate')).deleteSync();
    SeratoService(cat).importCrates(serato);
    final imported = crates.list().firstWhere(
      (c) => c.name == 'Wedding & Party' && c.id != wed.id,
    );
    expect(
      crates.count(imported.id),
      2,
      reason: 'the round trip keeps every track',
    );

    // rekordbox XML.
    final xmlPath = p.join(out.path, 'rekordbox.xml');
    final r = dj.exportRekordbox(xmlPath, crateIds: [folder.id, afro.id]);
    expect(
      () => dj.exportRekordbox(xmlPath),
      throwsA(isA<DjExportException>()),
      reason: 'never overwrites',
    );
    final xml = File(xmlPath).readAsStringSync();
    expect(xml, startsWith('<?xml'));
    expect(xml, contains('<DJ_PLAYLISTS Version="1.0.0">'));
    expect(xml, contains('<NODE Type="0" Name="Gigs"'));
    expect(
      xml,
      contains('Name="Wedding &amp; Party" Type="1" KeyType="0" Entries="2"'),
    );
    expect(xml, contains('Name="Afro" Type="1" KeyType="0" Entries="$afroN"'));
    expect(xml, contains('Location="file://localhost/'));
    expect(xml, contains('Deep%20Tenant%20-%20Warehouse%2094.mp3'));
    expect(r['tracks'], 2 + afroN);
    expect(
      DjExportService.fileUrl(r'C:\Music\A & B.mp3'),
      'file://localhost/C:/Music/A%20%26%20B.mp3',
    );

    // Folders: each crate copied and verified into its own folder.
    final usb = Directory(p.join(music.parent.path, 'USB'))..createSync();
    await dj.exportFolders(usb.path, crateIds: [folder.id]);
    final wdir = p.join(usb.path, 'Gigs', 'Wedding & Party');
    expect(File(p.join(wdir, 'playlist.m3u8')).existsSync(), isTrue);
    final copied = Directory(p.join(wdir, 'Music'))
        .listSync()
        .map((e) => p.basename(e.path));
    expect(
      copied.any((f) => f.endsWith('.mp3')) &&
          copied.any((f) => f.endsWith('.ogg')),
      isTrue,
    );
    before.removeWhere((k, _) => k.contains('_Serato_'));
    expect({
      for (final e in hashes(music).entries)
        if (!e.key.contains('_Serato_')) e.key: e.value,
    }, before);
  });

  test('Serato history CSV is matched without merging versions', () {
    final r = SeratoService(cat).importHistoryCsv(
      'name,artist,start time\n"Sunrise Groove (feat. Ada)",Lagos Lights,21:00\nSunrise Groove (Live),Lagos Lights,21:04\nUnknown,Nobody,21:08\n',
      'Friday',
    );
    expect(r, {'matched': 2, 'unmatched': 1});
    expect(SeratoService(cat).history().length, 3);
    expect(SeratoService(cat).clearHistory(), 3);
  });

  test('Studio files: new folders and files only, never replacing a WAV', () {
    final dir = studioNewFolder(out.path, 'Stems: Song?');
    expect(p.basename(dir), 'Stems Song');
    expect(
      p.basename(studioNewFolder(out.path, 'Stems: Song?')),
      'Stems Song (2)',
    );
    final f = studioWriteInto(dir, '../drums.wav', [1, 2, 3]);
    expect(p.dirname(f), dir, reason: 'never outside the folder');
    expect(
      () => studioWriteInto(dir, 'drums.wav', [4]),
      throwsA(isA<ExportException>()),
    );
    final path = p.join(out.path, 'mix.wav');
    studioSave(path, [1]);
    expect(
      () => studioSave(path, [2], overwrite: true),
      throwsA(isA<ExportException>()),
      reason: 'an existing WAV could be music',
    );
    final kit = p.join(out.path, 'kit.json');
    studioSave(kit, utf8.encode('{}'));
    studioSave(kit, utf8.encode('{"a":1}'), overwrite: true);
    expect(File(kit).readAsStringSync(), '{"a":1}');
  });
}
