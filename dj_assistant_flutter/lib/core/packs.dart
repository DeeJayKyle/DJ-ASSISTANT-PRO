import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../online/online.dart';
import 'catalogue.dart';
import 'jobs.dart';

/// Content packs (1.x `packs.rs`): large optional parts of the app (AI models)
/// downloaded once instead of riding along in every installer.
///
/// Each pack is a fixed list of files with known sizes and SHA-256 checksums.
/// Files download into `<base>/packs/<id>/<name>.part`, are verified, then
/// renamed into place; a pack counts as installed only when every file is
/// present and verified (recorded in `installed.json`). Downloads resume.
class PackFile {
  const PackFile(this.name, this.url, this.size, this.sha256);
  final String name, url, sha256;
  final int size;
}

class Pack {
  const Pack(this.id, this.name, this.description, this.credits, this.files);
  final String id, name, description, credits;
  final List<PackFile> files;
  int get size => files.fold(0, (a, f) => a + f.size);
}

class PackException implements Exception {
  PackException(this.message);
  final String message;
  @override
  String toString() => message;
}

const packsRelease =
    'https://github.com/DeeJayKyle/DJ-ASSISTANT-PRO/releases/download/packs-1/';

/// 2.0 runs the model with ONNX Runtime natively (DirectML on the graphics
/// card), so the browser runtime file of the 1.x pack is not needed.
const packs = <Pack>[
  Pack(
    'stems-ai',
    'Pro Stems AI',
    'AI stem separation (HTDemucs) for the Studio: much cleaner vocals, drums, bass and melodies than the built-in splitter. Runs on this computer, on your graphics card when it can (DirectML) or the processor.',
    'HTDemucs by Alexandre Défossez et al., Meta Platforms, Inc. (MIT licence). ONNX export by timcsy/demucs-web (MIT). ONNX Runtime by Microsoft (MIT).',
    [
      PackFile(
        'htdemucs_embedded.onnx',
        '${packsRelease}htdemucs_embedded.onnx',
        180534758,
        'e5e425c17683f163a472462eb5f5a4ffcd11c31858d57fbd0833b012d8b88077',
      ),
    ],
  ),
];

Pack? packById(String id) => packs.where((x) => x.id == id).firstOrNull;

String packDir(String base, String id) => p.join(base, 'packs', id);

bool packInstalled(String base, Pack pack) {
  final d = packDir(base, pack.id);
  return File(p.join(d, 'installed.json')).existsSync() &&
      pack.files.every((f) {
        final file = File(p.join(d, f.name));
        return file.existsSync() && file.lengthSync() == f.size;
      });
}

/// The path of one file of an installed pack, or null (names come from the
/// catalogue only, never from the caller).
String? packFilePath(String base, String id, String name) {
  final pack = packById(id);
  final f = pack?.files.where((f) => f.name == name).firstOrNull;
  if (pack == null || f == null || !packInstalled(base, pack)) return null;
  return p.join(packDir(base, id), f.name);
}

Future<String> sha256File(String path) async =>
    (await sha256.bind(File(path).openRead()).first).toString();

/// Downloads [url] into [dest], appending (resume); [progress] gets the bytes
/// now in the file and returns false to stop.
typedef Downloader = Future<void> Function(
  String url,
  String dest,
  bool Function(int bytes) progress,
);

/// Downloads, verifies and installs every file of [pack].
Future<void> installPack(
  String base,
  Pack pack,
  Downloader download,
  JobProgress prog,
) async {
  final d = Directory(packDir(base, pack.id))..createSync(recursive: true);
  prog.total = pack.size;
  var before = 0;
  void setDone(int n) {
    if (prog is JobContext) prog.progressTo(n);
  }

  for (final f in pack.files) {
    final target = File(p.join(d.path, f.name));
    final ok =
        target.existsSync() &&
        target.lengthSync() == f.size &&
        await sha256File(target.path) == f.sha256;
    if (!ok) {
      final part = File(p.join(d.path, '${f.name}.part'));
      // a partial file bigger than the real one can't be resumed
      if (part.existsSync() && part.lengthSync() > f.size) part.deleteSync();
      prog.message = 'Downloading ${f.name}…';
      var stop = false;
      try {
        await download(f.url, part.path, (now) {
          setDone(before + (now < f.size ? now : f.size));
          stop = prog is JobContext && prog.cancelled;
          return !stop;
        });
      } on Exception catch (e) {
        throw PackException(
          '$e. Check your internet connection and try again.',
        );
      }
      if (stop || await prog.checkpoint()) {
        prog.message =
            'Stopped. The download picks up where it left off next time.';
        return;
      }
      prog.message = 'Checking ${f.name}…';
      if (part.lengthSync() != f.size ||
          await sha256File(part.path) != f.sha256) {
        part.deleteSync();
        throw PackException(
          "${f.name} didn't download correctly (checksum mismatch). Try again.",
        );
      }
      part.renameSync(target.path);
    }
    before += f.size;
    setDone(before);
  }
  File(p.join(d.path, 'installed.json')).writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert({
      'id': pack.id,
      'files': [
        for (final f in pack.files) {'name': f.name, 'sha256': f.sha256},
      ],
      'installed_at': nowMs(),
    }),
  );
  prog.message = '${pack.name} is installed.';
}

/// The download job for a pack. Built here, at the top level, so the closure
/// sent to the job's isolate captures only these arguments: a closure written
/// inline in a page would drag the page's state along, which can't be sent,
/// and the download would never start.
JobBody packInstallJob(String base, String packId, Downloader download) =>
    (ctx) async {
      final pack = packById(packId);
      if (pack == null) throw PackException('unknown pack');
      await installPack(base, pack, download, ctx);
    };

/// A [Downloader] through [make] (the session's network factory), built at
/// the top level for the same reason as [packInstallJob].
Downloader packDownloader(Online Function() make) =>
    (url, dest, progress) => make().download(url, dest, progress);

/// Deletes a pack's files (only inside its own folder).
void removePack(String base, String id) {
  if (packById(id) == null) throw PackException('unknown pack');
  final d = Directory(packDir(base, id));
  if (d.existsSync()) d.deleteSync(recursive: true);
}

/// Every pack with its state, for Settings → Packs.
List<Map<String, Object?>> listPacks(String base, JobsController jobs) => [
  for (final x in packs)
    {
      'id': x.id,
      'name': x.name,
      'description': x.description,
      'credits': x.credits,
      'size': x.size,
      'installed': packInstalled(base, x),
      'download': jobs.status('pack:${x.id}').toJson(),
    },
];
