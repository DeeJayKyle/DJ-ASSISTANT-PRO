import 'dart:io';

import 'package:dj_assistant/core/catalogue.dart';
import 'package:dj_assistant/core/roots.dart';
import 'package:dj_assistant/core/scanner.dart';
import 'package:dj_assistant/core/upgrades.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'scanner_test.dart' show copyLibrary, hashes;

/// Upgrades: the configurable low-bitrate list, copies already owned, file
/// facts and loudness matching. Runs on a copy of the synthetic fixture
/// library; music files are only read.
void main() {
  late Directory music;
  late Catalogue cat;
  late UpgradeService up;

  setUp(() async {
    music = copyLibrary();
    cat = Catalogue.open(p.join(music.parent.path, 'catalogue.sqlite3'));
    RootsService(cat).add(music.path);
    await runScan(cat);
    up = UpgradeService(cat);
  });
  tearDown(() {
    cat.close();
    music.parent.deleteSync(recursive: true);
  });

  String nameOf(int id) =>
      cat.db.select('SELECT file_name FROM tracks WHERE id=?', [
            id,
          ]).first['file_name']
          as String;
  int idOf(String f) =>
      cat.db.select('SELECT id FROM tracks WHERE file_name=?', [f]).first['id']
          as int;

  test('lists lossy files under the warning level, lowest first', () {
    final before = hashes(music);
    expect(up.threshold, 128);
    final names = up.lowBitrateIds().map(nameOf).toList();
    expect(names, [
      'Neon Steps.m4a',
      'Mirrorball.ogg',
      'Deep Tenant - Warehouse 94.mp3',
      'Roller Rink.opus',
    ]);
    expect(
      names,
      isNot(contains('Low Tide.flac')),
      reason: 'lossless files are never flagged, whatever their bitrate',
    );
    cat.setSetting('low_bitrate_kbps', '90');
    expect(up.lowBitrateIds().map(nameOf), [
      'Neon Steps.m4a',
      'Mirrorball.ogg',
    ]);
    expect(hashes(music), before);
  });

  test('keep as it is hides a track until listed again', () {
    final id = idOf('Mirrorball.ogg');
    up.keep(id);
    expect(up.lowBitrateIds(), isNot(contains(id)));
    expect(up.lowBitrateIds(includeKept: true), contains(id));
    expect(up.keptIds(), {id});
    up.unkeep(id);
    expect(up.lowBitrateIds(), contains(id));
  });

  test('finds better copies already owned, best first', () {
    cat.setSetting('low_bitrate_kbps', '195');
    final a = idOf('Intro (album A).mp3');
    expect(up.lowBitrateIds(), contains(a));
    final owned = up.owned(a);
    expect(owned.map((o) => p.basename(o.facts.path)), ['Intro (album B).mp3']);
    expect(owned.single.reasons, ['197 kbps']);
    // A different artist with the same title is not offered.
    expect(up.owned(idOf('Deep Tenant - Warehouse 94.mp3')), isEmpty);
  });

  test('facts for a file outside the library come from its headers', () {
    final src = p.join(music.path, 'Lossless', 'Driftwood.aiff');
    final copy = p.join(music.parent.path, 'elsewhere', 'Driftwood.aiff');
    File(copy)
      ..createSync(recursive: true)
      ..writeAsBytesSync(File(src).readAsBytesSync());
    final f = up.fileFacts(copy);
    expect(f.trackId, isNull);
    expect(f.lossless, isTrue);
    expect(f.sampleRate, greaterThan(0));
    expect(f.lufs, isNull, reason: 'not analysed');
    final known = up.fileFacts(src);
    expect(known.trackId, idOf('Driftwood.aiff'));
  });

  test('loudness matching turns the louder file down', () {
    const quiet = AudioFacts(path: 'a', lufs: -14);
    const loud = AudioFacts(path: 'b', lufs: -8);
    expect(UpgradeService.matchGainDb(quiet, loud), -6);
    expect(UpgradeService.matchGainDb(loud, quiet), 6);
    expect(
      UpgradeService.matchGainDb(quiet, const AudioFacts(path: 'c')),
      isNull,
    );
    expect(bitrateCaveat, contains('not proof'));
  });
}
