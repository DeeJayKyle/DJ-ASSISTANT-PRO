import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:dj_assistant/app/session.dart';
import 'package:dj_assistant/core/blake3.dart';
import 'package:dj_assistant/core/catalogue.dart';
import 'package:dj_assistant/core/crates.dart';
import 'package:dj_assistant/core/inbox.dart';
import 'package:dj_assistant/core/scanner.dart';
import 'package:dj_assistant/online/online.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const fixture = 'test/fixtures/analysis/afro124_amin.flac';

void main() {
  late Directory dir, downloads, inbox;
  late Catalogue cat;
  late InboxService svc;
  final old = DateTime.now().subtract(const Duration(minutes: 5));

  /// A finished download (last changed minutes ago).
  File download(String name, {String from = fixture}) =>
      File(from).copySync(p.join(downloads.path, name))
        ..setLastModifiedSync(old);

  setUp(() {
    dir = Directory.systemTemp.createTempSync('inbox');
    downloads = Directory(p.join(dir.path, 'Downloads'))..createSync();
    inbox = Directory(p.join(dir.path, 'Music', 'DJ Assistant Inbox'));
    cat = Catalogue.open(p.join(dir.path, 'catalogue.sqlite3'));
    cat
      ..setSetting('inbox_enabled', '1')
      ..setSetting('inbox_downloads', downloads.path)
      ..setSetting('inbox_folder', inbox.path);
    svc = InboxService(cat);
  });
  tearDown(() {
    cat.close();
    dir.deleteSync(recursive: true);
  });

  test('only finished audio downloads and ZIPs are picked up', () {
    download('Track One.flac');
    download('Still going.mp3.crdownload');
    download('Other.part');
    download('cover.jpg');
    download('.hidden.flac');
    // changed a moment ago: may still be downloading
    // (copies keep the source's time on Windows, so set it explicitly)
    File(fixture)
        .copySync(p.join(downloads.path, 'Just now.flac'))
        .setLastModifiedSync(DateTime.now());
    expect(
      [for (final f in svc.ready()) p.basename(f.path)],
      ['Track One.flac'],
    );
    // once it has settled, it is picked up too
    final later = DateTime.now().millisecondsSinceEpoch + settleMs + 1000;
    expect(
      [for (final f in svc.ready(now: later)) p.basename(f.path)],
      ['Just now.flac', 'Track One.flac'],
    );
  });

  test('downloads are copied (verified), never moved, and imported once', () {
    final src = download('Artist - Title (Extended Mix).flac');
    final before = blake3File(src.path);
    final (paths, notes) = svc.importReady();
    expect(notes, isEmpty);
    expect(paths, hasLength(1));
    expect(p.isWithin(inbox.path, paths.single), isTrue);
    expect(p.basename(paths.single), 'Artist - Title (Extended Mix).flac');
    expect(blake3File(paths.single), before, reason: 'byte-for-byte copy');
    expect(src.existsSync(), isTrue, reason: 'the download stays');
    expect(blake3File(src.path), before, reason: 'and is unchanged');
    // a second check finds nothing new
    expect(svc.ready(), isEmpty);
    expect(svc.importReady().$1, isEmpty);
    // the same name downloaded again (a new file) is imported beside it
    src.deleteSync();
    download(
      'Artist - Title (Extended Mix).flac',
      from: 'test/fixtures/analysis/dnb174.flac',
    );
    final again = svc.importReady().$1.single;
    expect(p.basename(again), 'Artist - Title (Extended Mix) (2).flac');
  });

  test('ZIPs unpack audio only, every file kept inside the Inbox folder', () {
    final zipPath = p.join(dir.path, 'bundle.zip');
    final bytes = File(fixture).readAsBytesSync();
    final archive = Archive()
      ..addFile(ArchiveFile.bytes('Album/01 First.flac', bytes))
      ..addFile(ArchiveFile.bytes('../../escape.flac', bytes))
      ..addFile(ArchiveFile.bytes('cover.jpg', [1, 2, 3]))
      ..addFile(ArchiveFile.bytes('readme.txt', [65]));
    File(zipPath).writeAsBytesSync(ZipEncoder().encodeBytes(archive));
    download('Label - Album (Bandcamp).zip', from: zipPath);
    final (paths, notes) = svc.importReady();
    expect(notes, isEmpty);
    expect([for (final x in paths) p.basename(x)]..sort(), [
      '01 First.flac',
      'escape.flac',
    ]);
    for (final x in paths) {
      expect(p.isWithin(inbox.path, x), isTrue, reason: x);
      expect(p.basename(p.dirname(x)), 'Label - Album (Bandcamp)');
      expect(blake3File(x), blake3Hex(bytes));
    }
    expect(File(p.join(dir.path, 'escape.flac')).existsSync(), isFalse);
    expect(
      File(p.join(downloads.path, 'Label - Album (Bandcamp).zip')).existsSync(),
      isTrue,
    );
    expect(
      svc.importReady().$1,
      isEmpty,
      reason: 'the ZIP is not unpacked twice',
    );
  });

  test('a damaged ZIP is reported, not imported, and not retried', () {
    File(p.join(downloads.path, 'broken.zip'))
      ..writeAsBytesSync([80, 75, 3, 4, 0, 0, 1, 2, 3])
      ..setLastModifiedSync(old);
    final (paths, notes) = svc.importReady();
    expect(paths, isEmpty);
    expect(notes.single, startsWith('broken.zip:'));
    expect(svc.recent().first['status'], 'error');
    expect(svc.ready(), isEmpty);
  });

  test('the Inbox folder must be separate from the downloads folder', () {
    for (final bad in [downloads.path, p.join(downloads.path, 'Inbox')]) {
      cat.setSetting('inbox_folder', bad);
      expect(() => svc.validate(svc.settings), throwsA(isA<InboxException>()));
    }
  });

  test(
    'imported tracks are scanned into the library and the Inbox crate',
    () async {
      download('Track One.flac');
      download(
        'Track Two.flac',
        from: 'test/fixtures/analysis/house128_cmaj_stereo.flac',
      );
      final (paths, _) = svc.importReady();
      final root = svc.ensureRoot(inbox.path);
      expect(svc.ensureRoot(inbox.path), root, reason: 'added once');
      await runScan(cat, rootIds: [root]);
      expect(svc.addToCrate(paths), 2);
      final crate = svc.inboxCrate();
      expect(crate.name, inboxCrateName);
      expect(CratesService(cat).count(crate.id), 2);
    },
  );

  test('file names from ZIPs are made safe', () {
    expect(safeFileName('../../a/b/Song.mp3'), 'Song.mp3');
    expect(safeFileName(r'C:\x\Track: "One"?.flac'), 'Track_ _One__.flac');
    expect(safeFileName('...'), 'track');
    expect(safeFileName('.hidden.mp3'), 'hidden.mp3');
  });

  test(
    'the session imports, scans, fills the Inbox crate and runs auto-prep',
    () async {
      cat.close();
      final app = AppSession(
        dbPath: p.join(dir.path, 'catalogue.sqlite3'),
        online: NoOnline(),
        secrets: MemorySecrets(),
        onlineFactory: NoOnline.new,
      );
      cat = Catalogue.open(p.join(dir.path, 'catalogue.sqlite3'));
      addTearDown(app.close);
      download('Track One.flac');
      var imported = 0;
      app.inbox.onImported = () => imported++;
      final msg = await app.inbox.runNow();
      expect(msg, contains('Imported 1 track'));
      expect(msg, contains('Added 1 to the "Inbox" crate'));
      expect(imported, 1);
      final crate = InboxService(app.cat).inboxCrate();
      expect(CratesService(app.cat).count(crate.id), 1);
      // auto-prep was started for the new track
      final end = DateTime.now().add(const Duration(seconds: 60));
      while (app.jobs.running('auto_prep') && DateTime.now().isBefore(end)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(app.jobs.status('auto_prep').state, 'completed');
      // nothing new: nothing happens
      expect(await app.inbox.runNow(), isNot(contains('Imported')));
      // gig mode pauses it
      app.cat.setSetting('gig_mode', '1');
      expect(await app.inbox.runNow(), 'Paused in gig mode.');
    },
  );
}
