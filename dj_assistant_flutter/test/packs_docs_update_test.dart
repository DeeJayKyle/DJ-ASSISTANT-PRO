import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart' as c;
import 'package:cryptography/cryptography.dart';
import 'package:dj_assistant/core/catalogue.dart';
import 'package:dj_assistant/core/docs.dart';
import 'package:dj_assistant/core/jobs.dart';
import 'package:dj_assistant/core/packs.dart';
import 'package:dj_assistant/core/roots.dart';
import 'package:dj_assistant/core/updater.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('dja_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('packs (1.x packs.rs)', () {
    test('the catalogue is well formed', () {
      for (final x in packs) {
        for (final f in x.files) {
          expect(f.url, startsWith(packsRelease));
          expect(f.url, endsWith(f.name));
          expect(f.sha256.length, 64);
          expect(
            f.name.contains(RegExp(r'[/\\]')) || f.name.contains('..'),
            isFalse,
          );
        }
      }
    });

    test(
      'installs, resumes and verifies; removes only its own folder',
      () async {
        final body = Uint8List.fromList([
          for (var i = 0; i < 300000; i++) i % 251,
        ]);
        final pack = Pack('test-pack', 'Test', '', '', [
          PackFile(
            'model.bin',
            'https://example.test/model.bin',
            body.length,
            c.sha256.convert(body).toString(),
          ),
        ]);
        Downloader serve(Uint8List data) => (url, dest, progress) async {
          final f = File(dest);
          final have = f.existsSync() ? f.lengthSync() : 0;
          final out = f.openSync(mode: FileMode.append);
          for (var o = have; o < data.length; o += 65536) {
            out.writeFromSync(
              data,
              o,
              o + 65536 > data.length ? data.length : o + 65536,
            );
            if (!progress(out.lengthSync())) break;
          }
          out.closeSync();
        };
        // an interrupted earlier download left half the file behind
        final d = Directory(packDir(tmp.path, pack.id))
          ..createSync(recursive: true);
        File(p.join(d.path, 'model.bin.part'))
            .writeAsBytesSync(body.sublist(0, 150000));
        await installPack(tmp.path, pack, serve(body), LocalProgress());
        expect(packInstalled(tmp.path, pack), isTrue);
        expect(File(p.join(d.path, 'model.bin')).readAsBytesSync(), body);
        expect(File(p.join(d.path, 'model.bin.part')).existsSync(), isFalse);
        // a corrupted download is rejected and not installed
        final t2 = Directory.systemTemp.createTempSync('dja_');
        final bad = Uint8List.fromList(body)..[1000] ^= 1;
        await expectLater(
          installPack(t2.path, pack, serve(bad), LocalProgress()),
          throwsA(isA<PackException>()),
        );
        expect(packInstalled(t2.path, pack), isFalse);
        expect(
          File(p.join(packDir(t2.path, pack.id), 'model.bin')).existsSync(),
          isFalse,
        );
        t2.deleteSync(recursive: true);
        File(p.join(tmp.path, 'keep.txt')).writeAsStringSync('x');
        removePack(tmp.path, 'stems-ai');
        expect(File(p.join(tmp.path, 'keep.txt')).existsSync(), isTrue);
        expect(
          () => removePack(tmp.path, 'nope'),
          throwsA(isA<PackException>()),
        );
      },
    );

    test('file paths need an installed pack and a catalogue file', () {
      expect(
        packFilePath(tmp.path, 'stems-ai', 'htdemucs_embedded.onnx'),
        isNull,
      );
      expect(packFilePath(tmp.path, 'stems-ai', '../../secret'), isNull);
      expect(packFilePath(tmp.path, 'nope', 'x'), isNull);
    });
  });

  group('personal files (1.x docs.rs)', () {
    test('opt-in, separate from music, read-only, searchable', () async {
      final cat = Catalogue.inMemory();
      final music = Directory(p.join(tmp.path, 'Music'))..createSync();
      final docs = Directory(p.join(tmp.path, 'Docs'))..createSync();
      RootsService(cat).add(music.path);
      final pf = PersonalFiles(cat);
      expect(() => pf.addRoot(docs.path), throwsA(isA<DocsException>()));
      cat.setSetting('docs_enabled', '1');
      expect(
        () => pf.addRoot(p.join(music.path)),
        throwsA(isA<DocsException>()),
      );
      File(p.join(docs.path, 'setlist notes.txt'))
          .writeAsStringSync('Wedding at the Grand Hotel, first dance');
      File(p.join(docs.path, 'copy.txt'))
          .writeAsStringSync('Wedding at the Grand Hotel, first dance');
      File(p.join(docs.path, 'contract.pdf'))
          .writeAsStringSync('%PDF-1.4 /Encrypt 1 0 R');
      final enc = ZipEncoder().encode(
        Archive()..addFile(ArchiveFile.string('a.txt', 'x')),
      );
      File(p.join(docs.path, 'plain.zip')).writeAsBytesSync(enc);
      final docx = ZipEncoder().encode(
        Archive()..addFile(
          ArchiveFile.string(
            'word/document.xml',
            '<w:p><w:t>Rider</w:t><w:t>catering</w:t></w:p>',
          ),
        ),
      );
      File(p.join(docs.path, 'rider.docx')).writeAsBytesSync(docx);
      final before = {
        for (final f in docs.listSync().whereType<File>())
          f.path: f.readAsBytesSync(),
      };
      pf.addRoot(docs.path);
      await pf.scan(LocalProgress());
      final hits = pf.search('grand hotel');
      expect(hits, hasLength(2));
      expect(hits.first['snippet'] as String, contains('grand hotel'));
      expect(pf.search('catering').single['name'], 'rider.docx');
      final rep = pf.report();
      expect((rep['flagged'] as List).single['status'], 'encrypted');
      expect((rep['duplicates'] as List).single['paths'], hasLength(2));
      expect(zipEncrypted(p.join(docs.path, 'plain.zip')), isFalse);
      for (final e in before.entries) {
        expect(
          File(e.key).readAsBytesSync(),
          e.value,
          reason: 'files are only read',
        );
      }
      pf.clear();
      expect(pf.roots(), isEmpty);
      cat.close();
    });
  });

  group('updater', () {
    /// Signs like minisign / Tauri (prehashed "ED" or plain "Ed").
    Future<(String, String)> sign(
      Uint8List data, {
      bool prehash = true,
      String comment = 'timestamp:1\tfile:x.exe',
    }) async {
      final ed = Ed25519();
      final kp = await ed.newKeyPair();
      final pub = (await kp.extractPublicKey()).bytes;
      final id = [1, 2, 3, 4, 5, 6, 7, 8];
      final keyText =
          'untrusted comment: minisign public key\n${base64.encode([0x45, 0x64, ...id, ...pub])}\n';
      final msg = prehash ? (await Blake2b().hash(data)).bytes : data;
      final s = (await ed.sign(msg, keyPair: kp)).bytes;
      final g = (await ed.sign([
        ...s,
        ...utf8.encode(comment),
      ], keyPair: kp)).bytes;
      final sigText =
          'untrusted comment: signature\n'
          '${base64.encode([...utf8.encode(prehash ? 'ED' : 'Ed'), ...id, ...s])}\n'
          'trusted comment: $comment\n${base64.encode(g)}\n';
      return (
        base64.encode(utf8.encode(keyText)),
        base64.encode(utf8.encode(sigText)),
      );
    }

    test(
      'verifies minisign signatures, both forms, and rejects tampering',
      () async {
        final data = Uint8List.fromList(utf8.encode('installer bytes'));
        for (final pre in [true, false]) {
          final (key, sig) = await sign(data, prehash: pre);
          final k = parseMinisignKey(key);
          expect(await verifyMinisign(data, sig, k), isTrue);
          expect(
            await verifyMinisign(Uint8List.fromList([...data, 0]), sig, k),
            isFalse,
          );
          final text = utf8
              .decode(base64.decode(sig))
              .replaceFirst('file:x.exe', 'file:y.exe');
          expect(
            await verifyMinisign(data, text, k),
            isFalse,
            reason: 'trusted comment changed',
          );
        }
        // the app's real key parses (key id 27B78D87895CDD23)
        final real = parseMinisignKey(updaterPublicKey);
        expect(
          real.keyId.reversed
              .map((b) => b.toRadixString(16).padLeft(2, '0'))
              .join()
              .toUpperCase(),
          '27B78D87895CDD23',
        );
      },
    );

    test('reads the manifest and only offers newer versions', () async {
      expect(isNewer('2.0.0', '1.8.1'), isTrue);
      expect(isNewer('1.8.1', '2.0.0'), isFalse);
      expect(isNewer('2.0.0', '2.0.0-beta.1'), isTrue);
      expect(isNewer('2.0.0', '2.0.0'), isFalse);
      final data = Uint8List.fromList([1, 2, 3]);
      final (key, sig) = await sign(data);
      final client = MockClient((r) async {
        if (r.url.path.endsWith('latest.json')) {
          return http.Response(
            jsonEncode({
              'version': '2.1.0',
              'notes': 'n',
              'platforms': {
                updatePlatform: {
                  'url': 'https://example.test/setup.exe',
                  'signature': sig,
                },
              },
            }),
            200,
          );
        }
        return http.Response.bytes(data, 200);
      });
      final u = (await checkForUpdate(
        client,
        '2.0.0',
        endpoints: ['https://example.test/latest.json'],
      ))!;
      expect(u.version, '2.1.0');
      expect(
        await checkForUpdate(
          client,
          '2.1.0',
          endpoints: ['https://example.test/latest.json'],
        ),
        isNull,
      );
      final dest = p.join(tmp.path, 'setup.exe');
      await downloadUpdate(client, u, dest, publicKey: key);
      expect(File(dest).readAsBytesSync(), data);
      await expectLater(
        downloadUpdate(client, u, p.join(tmp.path, 'bad.exe')),
        throwsA(isA<UpdateException>()),
        reason: 'signed by another key',
      );
      expect(File(p.join(tmp.path, 'bad.exe')).existsSync(), isFalse);
    });
  });
}
