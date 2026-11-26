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
      // PATH as this computer writes it (";" and beet.exe on Windows)
      final win = Platform.isWindows;
      final bin = Directory(p.join(tmp.path, 'bin'))..createSync();
      final exe = p.join(bin.path, win ? 'beet.exe' : 'beet');
      File(exe).writeAsStringSync('');
      final beets = taggerById('beets')!;
      expect(
        findTool(
          beets,
          env: {'PATH': '${tmp.path}${win ? ';' : ':'}${bin.path}'},
          windows: win,
        ),
        exe,
      );
      expect(findTool(beets, env: {'PATH': ''}, windows: win), isNull);
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
