import 'dart:io';

import 'package:dj_assistant/core/catalogue.dart';
import 'package:dj_assistant/core/roots.dart';
import 'package:dj_assistant/core/scanner.dart';
import 'package:dj_assistant/core/suggestions.dart';
import 'package:dj_assistant/core/tag_writer.dart';
import 'package:dj_assistant/core/taggers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'scanner_test.dart' show copyLibrary, hashes;

/// External taggers: every tool works on its own copies, the originals are
/// never written, and what the tools find is merged into review-first
/// suggestions with agreement raising confidence.
void main() {
  group('merging what the tools found', () {
    test('agreement raises confidence; disagreement lowers it', () {
      final merged = mergeFindings({
        'onetagger': {
          1: {'genre': 'Afro House', 'bpm': '122', 'key': 'Am'},
        },
        'beets': {
          1: {'genre': 'afro  house', 'year': '2019'},
        },
        'picard': {
          1: {'genre': 'House', 'year': '2019'},
        },
        'mp3tag': {
          1: {'key': '8A', 'bpm': '122.0'},
        },
      });
      MergedSuggestion of(String f) => merged.firstWhere((m) => m.field == f);
      final genre = of('genre');
      expect(genre.value, 'Afro House');
      expect(genre.tools, ['onetagger', 'beets']);
      expect(genre.evidence, contains('Picard said “House”'));
      // OneTagger 0.80 + 0.07 for beets − 0.12 for Picard disagreeing
      expect(genre.confidence, closeTo(0.75, 1e-9));
      expect(of('key').tools, ['onetagger', 'mp3tag'], reason: 'Am is 8A');
      expect(of('key').confidence, closeTo(0.97, 1e-9), reason: 'capped');
      expect(of('bpm').tools.length, 2, reason: '122 and 122.0 agree');
      expect(of('year').evidence, 'beets + MusicBrainz Picard agree');
    });

    test('the same fact written differently agrees', () {
      void same(String f, String a, String b) =>
          expect(agreeKey(f, a), agreeKey(f, b), reason: '$f: $a = $b');
      void differ(String f, String a, String b) =>
          expect(agreeKey(f, a), isNot(agreeKey(f, b)), reason: '$f: $a ≠ $b');
      same('title', 'Danfo Ride (Original Mix)', 'Danfo Ride');
      same('title', 'Danfo Ride [Extended Mix]', 'Danfo Ride (Extended Mix)');
      same('title', 'Danfo Ride (feat. Ada)', 'Danfo Ride');
      same('title', 'Danfo Ride feat. Ada (Club Mix)', 'Danfo Ride (Club Mix)');
      differ('title', 'Danfo Ride (Extended Mix)', 'Danfo Ride');
      same('artist', 'Kito Lagoon feat. Ada', 'Kito Lagoon ft. Ada');
      same('artist', 'Kito Lagoon & Ada', 'Ada, Kito Lagoon');
      same('artist', 'Kito Lagoon x Ada', 'Kito Lagoon and Ada');
      differ('artist', 'Kito Lagoon', 'Kito Lagoon & Ada');
      same('genre', 'Hip-Hop', 'Hip Hop');
      same('genre', 'R&B', 'RnB');
      same('genre', 'Afro House', 'AfroHouse');
      differ('genre', 'House', 'Afro House');
      same('record_label', 'Defected Records', 'Defected');
      same('record_label', 'Mavin Music Ltd', 'Mavin');
      same('year', '2019-05-03', '2019');
    });

    test('values compare without case, accents or extra spaces', () {
      expect(agreeKey('genre', 'Afro  House'), agreeKey('genre', 'afro house'));
      expect(agreeKey('artist', 'Beyoncé'), agreeKey('artist', 'beyonce'));
      expect(agreeKey('key', 'A minor'), agreeKey('key', '8A'));
      expect(agreeKey('bpm', '127.9'), agreeKey('bpm', '128'));
    });
  });

  group('finding the tools', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('dja_tools'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('a set path wins; otherwise PATH, then usual Windows folders', () {
      final bin = Directory(p.join(tmp.path, 'bin'))..createSync();
      File(p.join(bin.path, 'beet')).writeAsStringSync('');
      final beets = taggerById('beets')!;
      expect(
        findTool(beets, env: {'PATH': bin.path}, windows: false),
        p.join(bin.path, 'beet'),
      );
      expect(findTool(beets, env: {'PATH': ''}, windows: false), isNull);
      final mine = File(p.join(tmp.path, 'my-beet'))..writeAsStringSync('');
      expect(
        findTool(beets, configured: mine.path, env: const {}, windows: false),
        mine.path,
      );
      expect(
        findTool(beets, configured: '/nope/beet', env: {'PATH': bin.path}),
        isNull,
        reason: 'a path the DJ set that is gone is reported, not guessed',
      );
      final pf = Directory(p.join(tmp.path, 'PF', 'Mp3tag'))
        ..createSync(recursive: true);
      File(p.join(pf.path, 'Mp3tag.exe')).writeAsStringSync('');
      expect(
        findTool(
          taggerById('mp3tag')!,
          env: {'PATH': '', 'ProgramFiles': p.join(tmp.path, 'PF')},
          windows: true,
        ),
        isNotNull,
      );
    });
  });

  group('workspaces on a scanned library', () {
    late Directory music;
    late Catalogue cat;
    late TaggerService svc;
    late Map<String, String> before;

    setUp(() async {
      music = copyLibrary();
      cat = Catalogue.open(p.join(music.parent.path, 'catalogue.sqlite3'));
      RootsService(cat).add(music.path);
      await runScan(cat);
      svc = TaggerService(cat, music.parent.path);
      before = hashes(music);
    });
    tearDown(() {
      cat.close();
      music.parent.deleteSync(recursive: true);
    });

    int idOf(String f) =>
        cat.db.select('SELECT id FROM tracks WHERE file_name=?', [
              f,
            ]).first['id']
            as int;

    /// A stand-in tool: writes [tags] into every copy it was given.
    ToolRunner fakeTool(Map<String, String> tags, {int exit = 0}) =>
        (exe, args, {environment, workingDirectory}) async {
          for (final f in Directory(
            workingDirectory!,
          ).listSync(recursive: true).whereType<File>()) {
            final kind = writableKind(f.path);
            if (kind != null) writeTagsInPlace(f.path, kind, tags);
          }
          return ProcessResult(1, exit, 'tagged', exit == 0 ? '' : 'boom');
        };

    test('tools work on their own copies and never touch the music', () async {
      final mp3 = idOf('Lagos Lights - Sunrise Groove.mp3');
      final flac = idOf('Low Tide.flac');
      final ws = svc.create([mp3, flac], label: 'test');
      expect(ws.tracks.length, 2);
      expect(ws.tracks.first['before'], containsPair('genre', 'Afrobeats'));

      final one = await runAutomaticTool(
        ws,
        'onetagger',
        '/x/onetagger-cli',
        run: fakeTool({'genre': 'Afro House', 'bpm': '104', 'key': 'Am'}),
      );
      await runAutomaticTool(
        ws,
        'beets',
        '/x/beet',
        run: fakeTool({'genre': 'Afro House', 'year': '2016'}),
      );
      // the MP3 already says 104 BPM and 8A (Am is 8A): only real changes
      // are findings
      expect(one[mp3], {'genre': 'Afro House'});
      expect(one[flac]!['genre'], 'Afro House');
      expect(
        File(ws.copyPath('onetagger', ws.tracks.first)).existsSync(),
        isTrue,
      );
      expect(
        ws.copyPath('onetagger', ws.tracks.first),
        isNot(ws.copyPath('beets', ws.tracks.first)),
        reason: 'each tool has its own copies, so opinions stay independent',
      );
      expect(hashes(music), before, reason: 'the music was never written');

      final reloaded = TaggerWorkspace.load(ws.dir);
      expect(reloaded.findings.keys, containsAll(['onetagger', 'beets']));
      expect(svc.merge(reloaded), greaterThan(0));
      final sug = SuggestionsService(cat)
          .list(status: 'pending')
          .where((s) => s.source == 'taggers' && s.trackId == mp3)
          .toList();
      final genre = sug.firstWhere((s) => s.field == 'genre');
      expect(genre.suggestedValue, 'Afro House');
      expect(genre.currentValue, 'Afrobeats');
      expect(genre.evidence, 'OneTagger + beets agree');
      expect(genre.confidence, closeTo(0.87, 1e-9));
      expect(
        sug.where((s) => s.field == 'year'),
        isEmpty,
        reason: 'beets wrote the year the track already has',
      );
      expect(hashes(music), before);

      // accepting changes the catalogue, never the file
      SuggestionsService(cat).accept(genre.id);
      expect(hashes(music), before);
    });

    test('a tool that fails says why and leaves nothing behind', () async {
      final ws = svc.create([idOf('Low Tide.flac')]);
      await expectLater(
        runAutomaticTool(
          ws,
          'beets',
          '/x/beet',
          run: fakeTool(const {}, exit: 2),
        ),
        throwsA(
          isA<TaggerException>().having(
            (e) => e.message,
            'message',
            allOf(contains('beets stopped'), contains('boom')),
          ),
        ),
      );
      expect(File(ws.logPath('beets')).readAsStringSync(), contains('exit 2'));
      expect(hashes(music), before);
    });

    test('the command lines', () {
      final ws = svc.create([idOf('Low Tide.flac')]);
      final (ot, _) = automaticCommand(ws, 'onetagger');
      expect(ot.take(3), ['autotagger', '--path', ws.toolDir('onetagger')]);
      expect(ot, containsAll(['--overwrite', defaultOneTaggerPlatforms]));
      final (beet, env) = automaticCommand(
        ws,
        'beets',
        beetsPlugins: 'lastgenre, rm -rf',
      );
      expect(beet, contains('-s'));
      expect(beet.last, ws.toolDir('beets'));
      expect(env!['BEETSDIR'], p.join(ws.dir, 'beets'));
      final cfg = File(p.join(ws.dir, 'beets', 'config.yaml'))
          .readAsStringSync();
      expect(cfg, contains('copy: no'));
      expect(cfg, contains('move: no'));
      expect(cfg, contains('plugins: lastgenre rm'));
      expect(cfg, isNot(contains('-rf')));
      expect(interactiveCommand(ws, 'mp3tag'), ['/fp:${ws.toolDir('mp3tag')}']);
      expect(interactiveCommand(ws, 'picard'), [ws.toolDir('picard')]);
      expect(() => automaticCommand(ws, 'picard'), throwsA(anything));
    });

    test('incomplete tracks and workspaces are listed and removed', () {
      final ids = svc.incompleteTracks();
      expect(ids, isNotEmpty);
      expect(svc.incompleteTracks(limit: 2).length, 2);
      final ws = svc.create(ids.take(3).toList());
      expect(svc.workspaces().single.id, ws.id);
      svc.remove(ws);
      expect(svc.workspaces(), isEmpty);
      expect(hashes(music), before);
    });

    test(
      'real beets, when installed, runs on the copies only',
      () async {
        final exe = findTool(taggerById('beets')!);
        final ws = svc.create([
          idOf('Lagos Lights - Sunrise Groove.mp3'),
          idOf('Low Tide.flac'),
        ]);
        try {
          await runAutomaticTool(
            ws,
            'beets',
            exe!,
            timeout: const Duration(minutes: 3),
          );
        } on TaggerException {
          // offline machines: beets may stop, but must not touch the music
        }
        expect(File(ws.logPath('beets')).existsSync(), isTrue);
        expect(hashes(music), before);
      },
      skip: findTool(taggerById('beets')!) == null
          ? 'beets not installed'
          : null,
      timeout: const Timeout(Duration(minutes: 4)),
    );
  });
}
