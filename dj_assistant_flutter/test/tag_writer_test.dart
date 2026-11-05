import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dj_assistant/core/tag_writer.dart';
import 'package:dj_assistant/core/tags.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

final lib = p.join('..', 'crates', 'dj-core', 'tests', 'fixtures', 'library');
final hasFfprobe =
    Process.runSync('sh', ['-c', 'command -v ffprobe']).exitCode == 0;

// ---------------------------------------------------------------- builders

List<int> _ss(int n) => [
  (n >> 21) & 0x7F,
  (n >> 14) & 0x7F,
  (n >> 7) & 0x7F,
  n & 0x7F,
];
List<int> _be(int n) => [
  n >> 24 & 0xFF,
  n >> 16 & 0xFF,
  n >> 8 & 0xFF,
  n & 0xFF,
];

List<int> frame(int major, String id, List<int> data) => [
  ...latin1.encode(id),
  ...(major == 4 ? _ss(data.length) : _be(data.length)),
  0,
  0,
  ...data,
];

List<int> textFrame(int major, String id, String v) => frame(major, id, [
  major == 4 ? 3 : 0,
  ...(major == 4 ? utf8.encode(v) : latin1.encode(v)),
]);

/// Bytes of a Serato-like "Serato Markers2" GEOB frame (binary payload).
final geobPayload = [
  0,
  ...latin1.encode('application/octet-stream'),
  0,
  0,
  ...latin1.encode('Serato Markers2'),
  0,
  for (var i = 0; i < 300; i++) (i * 37 + 11) & 0xFF,
];
final apicPayload = [
  0,
  ...latin1.encode('image/png'),
  0,
  3,
  0,
  0x89,
  0x50,
  0x4E,
  0x47,
  for (var i = 0; i < 64; i++) i,
];

Uint8List mp3Audio() {
  final b = File(p.join(lib, 'Afrobeats', 'Lagos Lights - Sunrise Groove.mp3'))
      .readAsBytesSync();
  final size = (b[6] << 21) | (b[7] << 14) | (b[8] << 7) | b[9];
  return Uint8List.sublistView(b, 10 + size);
}

/// A DJ's MP3: title, artist, Serato GEOB, cover art, TXXX, a described COMM and
/// the plain comment, with [padding] bytes of room.
File serateMp3(Directory dir, int major, {int padding = 512}) {
  final frames = [
    ...textFrame(major, 'TIT2', 'Sunrise Groove'),
    ...textFrame(major, 'TPE1', 'Lagos Lights'),
    ...frame(major, 'GEOB', geobPayload),
    ...frame(major, 'APIC', apicPayload),
    ...frame(major, 'TXXX', [
      0,
      ...latin1.encode('SERATO_PLAYCOUNT'),
      0,
      ...latin1.encode('7'),
    ]),
    ...frame(major, 'COMM', [
      0,
      ...latin1.encode('eng'),
      ...latin1.encode('iTunNORM'),
      0,
      ...latin1.encode(' 0000 1111'),
    ]),
    ...frame(major, 'COMM', [
      0,
      ...latin1.encode('eng'),
      0,
      ...latin1.encode('old comment'),
    ]),
    ...textFrame(major, 'TBPM', '104'),
  ];
  final size = frames.length + padding;
  final f = File(p.join(dir.path, 'serato_v2$major.mp3'))
    ..writeAsBytesSync([
      0x49,
      0x44,
      0x33,
      major,
      0,
      0,
      ..._ss(size),
      ...frames,
      ...List.filled(padding, 0),
      ...mp3Audio(),
    ]);
  return f;
}

/// Low Tide.flac with SERATO_* comments and a picture, with or without padding.
File seratoFlac(Directory dir, {bool padding = true}) {
  final b = File(p.join(lib, 'Lossless', 'Low Tide.flac')).readAsBytesSync();
  final blocks = <(int, List<int>)>[];
  var q = 4;
  while (true) {
    final last = b[q] & 0x80 != 0,
        t = b[q] & 0x7F,
        n = (b[q + 1] << 16) | (b[q + 2] << 8) | b[q + 3];
    blocks.add((t, b.sublist(q + 4, q + 4 + n)));
    q += 4 + n;
    if (last) break;
  }
  List<int> le(int n) => [
    n & 0xFF,
    n >> 8 & 0xFF,
    n >> 16 & 0xFF,
    n >> 24 & 0xFF,
  ];
  final entries = [
    'TITLE=Low Tide',
    'ARTIST=Quiet Harbour',
    'SERATO_MARKERS_V2=QXBwbGljYXRpb24vb2N0ZXQtc3RyZWFt',
    'DATE=2021',
  ];
  final vendor = utf8.encode('reference libFLAC 1.4.3');
  final vc = [
    ...le(vendor.length),
    ...vendor,
    ...le(entries.length),
    for (final e in entries) ...[
      ...le(utf8.encode(e).length),
      ...utf8.encode(e),
    ],
  ];
  final pic = [
    0,
    0,
    0,
    3,
    ..._be(9),
    ...latin1.encode('image/png'),
    ..._be(0),
    ..._be(1),
    ..._be(1),
    ..._be(24),
    ..._be(0),
    ..._be(8),
    1,
    2,
    3,
    4,
    5,
    6,
    7,
    8,
  ];
  final out = <(int, List<int>)>[
    blocks.first,
    (4, vc),
    (6, pic),
    if (padding) (1, List.filled(4096, 0)),
  ];
  final bytes = BytesBuilder()..add(latin1.encode('fLaC'));
  for (var i = 0; i < out.length; i++) {
    final (t, d) = out[i];
    bytes
      ..add([
        (i == out.length - 1 ? 0x80 : 0) | t,
        d.length >> 16 & 0xFF,
        d.length >> 8 & 0xFF,
        d.length & 0xFF,
      ])
      ..add(d);
  }
  bytes.add(b.sublist(q));
  return File(p.join(dir.path, padding ? 'serato.flac' : 'nopad.flac'))
    ..writeAsBytesSync(bytes.takeBytes());
}

File copyTo(Directory dir, String src, String name) =>
    File(src).copySync(p.join(dir.path, name));

Map<String, String> ffprobeTags(String path) {
  final r = Process.runSync('ffprobe', [
    '-v',
    'error',
    '-show_entries',
    'format_tags',
    '-of',
    'json',
    path,
  ]);
  final tags =
      ((jsonDecode(r.stdout as String) as Map)['format'] as Map?)?['tags']
          as Map? ??
      {};
  return {
    for (final e in tags.entries) (e.key as String).toLowerCase(): '${e.value}',
  };
}

/// Writes [changes] and checks everything that must and must not change.
void writeAndVerify(File f, String kind, Map<String, String?> changes) {
  final before = audioHash(f.path, kind);
  final untouched = untouchedTags(f.path, kind, changes.keys);
  final keepCurrent = readWritableTags(f.path, kind)
    ..removeWhere((k, _) => changes.containsKey(k));
  writeTagsInPlace(f.path, kind, changes);
  expect(
    audioHash(f.path, kind),
    before,
    reason: 'audio data must be identical',
  );
  expect(
    untouchedTags(f.path, kind, changes.keys),
    untouched,
    reason: 'other tag data must be preserved',
  );
  final now = readWritableTags(f.path, kind);
  for (final e in changes.entries) {
    expect(now[e.key], e.value ?? isNull, reason: 'writer read-back: ${e.key}');
  }
  for (final e in keepCurrent.entries) {
    expect(now[e.key], e.value, reason: 'unedited field ${e.key}');
  }
  // An independent reader (the scanner's) agrees.
  final m = readAudioMeta(f.path);
  final scanned = {
    'title': m.title,
    'artist': m.artist,
    'album': m.album,
    'genre': m.genre,
    'comment': m.comment,
    'key': m.key,
  };
  for (final k in scanned.keys) {
    if (changes.containsKey(k) && changes[k] != null) {
      expect(scanned[k], changes[k], reason: 'scanner read-back: $k');
    }
  }
  if (changes['year'] != null) {
    expect(m.year, int.parse(changes['year']!.substring(0, 4)));
  }
  if (changes['bpm'] != null) expect(m.bpm, double.parse(changes['bpm']!));
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('dja-tags-'));
  tearDown(() => dir.deleteSync(recursive: true));

  const all = {
    'title': 'Sunrise Groove (Extended Mix)',
    'artist': 'Lagos Lights',
    'album': 'Coastline',
    'genre': 'Afro House',
    'year': '2016',
    'bpm': '124',
    'key': '8A',
    'comment': 'cued for the opening set',
  };

  for (final major in [3, 4]) {
    group('MP3 ID3v2.$major with Serato data', () {
      test(
        'every field, inside the existing padding (audio does not move)',
        () {
          final f = serateMp3(dir, major, padding: 2048);
          final len = f.lengthSync();
          writeAndVerify(f, 'mp3', all);
          expect(
            f.lengthSync(),
            len,
            reason: 'fits in the padding, so the file size is unchanged',
          );
        },
      );
      test('larger than the padding: the tag grows, the audio is kept', () {
        final f = serateMp3(dir, major, padding: 0);
        writeAndVerify(f, 'mp3', {'comment': 'x' * 3000, 'title': 'Long'});
      });
      test('non-Latin text', () {
        final f = serateMp3(dir, major);
        writeAndVerify(f, 'mp3', {
          'title': 'Déjà Vu – 日本語 🎧',
          'artist': 'Beyoncé',
        });
      });
      test('removing fields leaves the rest, including the described COMM', () {
        final f = serateMp3(dir, major);
        writeAndVerify(f, 'mp3', {'comment': null, 'bpm': null});
        final raw = f.readAsBytesSync();
        expect(latin1.decode(raw, allowInvalid: true), contains('iTunNORM'));
        expect(
          latin1.decode(raw, allowInvalid: true),
          contains('Serato Markers2'),
        );
      });
    });
  }

  test('an MP3 without any ID3 tag gets a new 2.4 tag', () {
    final f = File(p.join(dir.path, 'bare.mp3'))..writeAsBytesSync(mp3Audio());
    writeAndVerify(f, 'mp3', {'title': 'Bare', 'year': '2020'});
    expect(f.readAsBytesSync()[3], 4);
  });

  test('every library MP3 fixture can be edited and re-read', () {
    for (final src
        in Directory(lib)
            .listSync(recursive: true)
            .whereType<File>()
            .where(
              (x) => x.path.endsWith('.mp3') && !x.path.contains('Broken'),
            )) {
      final f = copyTo(dir, src.path, 'lib.mp3');
      writeAndVerify(f, 'mp3', {'genre': 'Afro House', 'key': '8A'});
    }
  });

  group('FLAC', () {
    test('every field; the padding absorbs the change', () {
      final f = seratoFlac(dir);
      final len = f.lengthSync();
      writeAndVerify(f, 'flac', all);
      expect(f.lengthSync(), len);
      expect(
        utf8.decode(f.readAsBytesSync(), allowMalformed: true),
        contains('SERATO_MARKERS_V2='),
      );
    });
    test('no padding block: the comment block still grows safely', () {
      final f = seratoFlac(dir, padding: false);
      writeAndVerify(f, 'flac', {
        'comment': 'y' * 5000,
        'title': 'Low Tide (Edit)',
      });
    });
    test(
      'removing a field',
      () => writeAndVerify(seratoFlac(dir), 'flac', {'year': null}),
    );
  });

  group('M4A', () {
    const m4a = {
      'title': 'Neon Steps (Club Mix)',
      'artist': 'Velvet Arcade',
      'album': 'Night Shift',
      'genre': 'House',
      'year': '2019',
      'comment': 'warm-up',
    };
    test('movie header after the audio', () {
      writeAndVerify(
        copyTo(dir, p.join(lib, 'House', 'Neon Steps.m4a'), 'a.m4a'),
        'm4a',
        m4a,
      );
    });
    test('ALAC', () {
      writeAndVerify(
        copyTo(dir, p.join(lib, 'Lossless', 'Shoreline.m4a'), 'b.m4a'),
        'm4a',
        {'title': 'Shoreline', 'genre': 'Ambient'},
      );
    });
    test('movie header before the audio: chunk offsets move with it', () {
      final f = copyTo(dir, 'test/fixtures/tags/faststart.m4a', 'c.m4a');
      writeAndVerify(f, 'm4a', {...m4a, 'comment': 'z' * 500});
      // The audio must still decode exactly as before (offsets were patched).
      final ref =
          Process.runSync('sh', ['-c', 'command -v ffmpeg']).exitCode == 0;
      if (ref) {
        String pcm(String path) =>
            (Process.runSync('ffmpeg', [
                      '-v',
                      'error',
                      '-i',
                      path,
                      '-f',
                      'md5',
                      '-',
                    ]).stdout
                    as String)
                .trim();
        expect(pcm(f.path), pcm('test/fixtures/tags/faststart.m4a'));
      }
    });
    test('movie header before the audio, smaller tag', () {
      writeAndVerify(
        copyTo(dir, 'test/fixtures/tags/faststart.m4a', 'd.m4a'),
        'm4a',
        {'title': null},
      );
    });
  });

  test('other apps read what was written', () {
    final mp3 = serateMp3(dir, 3);
    writeTagsInPlace(mp3.path, 'mp3', all);
    final flac = seratoFlac(dir);
    writeTagsInPlace(flac.path, 'flac', all);
    final m4a = copyTo(dir, 'test/fixtures/tags/faststart.m4a', 'e.m4a');
    writeTagsInPlace(m4a.path, 'm4a', {
      'title': 'Neon Steps',
      'artist': 'Velvet Arcade',
      'year': '2019',
    });
    for (final f in [mp3, flac]) {
      final t = ffprobeTags(f.path);
      expect(t['title'], all['title']);
      expect(t['artist'], all['artist']);
      expect(t['genre'], all['genre']);
    }
    final t = ffprobeTags(m4a.path);
    expect(t['title'], 'Neon Steps');
    expect(t['date'], '2019');
  }, skip: hasFfprobe ? null : 'ffprobe is not installed');

  test('unusual layouts are refused, not rewritten', () {
    final f = File(
      p.join(dir.path, 'v22.mp3'),
    )..writeAsBytesSync([0x49, 0x44, 0x33, 2, 0, 0, 0, 0, 0, 0, ...mp3Audio()]);
    expect(
      () => writeTagsInPlace(f.path, 'mp3', {'title': 'x'}),
      throwsA(isA<TagWriteException>()),
    );
    final ext = File(p.join(dir.path, 'ext.mp3'))
      ..writeAsBytesSync([
        0x49,
        0x44,
        0x33,
        3,
        0,
        0x40,
        0,
        0,
        0,
        0,
        ...mp3Audio(),
      ]);
    expect(
      () => writeTagsInPlace(ext.path, 'mp3', {'title': 'x'}),
      throwsA(isA<TagWriteException>()),
    );
  });
}
