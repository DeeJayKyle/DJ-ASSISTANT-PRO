import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:cryptography/cryptography.dart';
import 'package:dj_assistant/core/catalogue.dart';
import 'package:dj_assistant/core/jobs.dart';
import 'package:dj_assistant/core/roots.dart';
import 'package:dj_assistant/core/updater.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

import 'open_files.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('dja_'));
  tearDown(() {
    expectNoOpenFiles(tmp);
    tmp.deleteSync(recursive: true);
  });

  group('personal files (1.x docs.rs)', () {
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

      // automatic updates: staged in the background, kept until installed
      final dir = p.join(tmp.path, 'updates');
      final staged = await stageUpdate(client, u, dir, publicKey: key);
      expect(File(staged.path).readAsBytesSync(), data);
      final again = stagedUpdate(dir, '2.0.0')!;
      expect((again.version, again.path), ('2.1.0', staged.path));
      // once that version (or a later one) runs, the waiting copy is cleared
      expect(stagedUpdate(dir, '2.1.0'), isNull);
      expect(Directory(dir).existsSync(), isFalse);
      // a tampered installer is never started
      await stageUpdate(client, u, dir, publicKey: key);
      File(staged.path).writeAsBytesSync([9, 9, 9]);
      await expectLater(
        installStaged(stagedUpdate(dir, '2.0.0')!, publicKey: key),
        throwsA(isA<UpdateException>()),
      );
    });
  });
}
