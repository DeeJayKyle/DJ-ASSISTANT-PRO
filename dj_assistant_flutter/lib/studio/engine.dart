import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart' show calloc;

import '../audio/pcm.dart';
import '../core/diag_log.dart';
import 'ai_stems.dart';
import 'dsp.dart';
import 'midi.dart';
import 'onnx_model.dart';
import 'remix.dart';
import 'stems.dart';

/// The Studio engine (1.x `src/studio/engine.ts`): decodes songs, analyses
/// them, runs separation on every core, keeps results per song, renders
/// remixes. Heavy work runs in isolates so the UI never stalls.
class SongRef {
  const SongRef({
    required this.id,
    required this.title,
    required this.path,
    this.artist,
    this.bpm,
    this.key,
  });
  final String id, title, path;
  final String? artist, key;
  final double? bpm;
}

class Analysis {
  Analysis(this.bpm, this.firstBeat, this.key, this.chords);
  final double bpm, firstBeat;
  final KeyResult key;
  final List<ChordSegment> chords;
}

class Loaded {
  Loaded(this.song, this.sampleRate, this.mix);
  final SongRef song;
  final int sampleRate;
  final List<Float32List> mix;
  Analysis? analysis;
  Stems? stems, aiStems, fastStems;

  /// How [stems] were made: 'ai' (Pro Stems AI) or 'fast' (signal processing).
  String? stemsBy;
  double get durationSec => mix[0].length / sampleRate;
}

class StudioException implements Exception {
  StudioException(this.message, {this.fallback = false, this.detail});
  final String message;
  final bool fallback;

  /// The underlying reason (decoder or runtime message), shown on the page
  /// and written to the diagnostics log.
  final String? detail;

  /// A stack trace from the isolate that failed, for the log only.
  String? stack;

  @override
  String toString() =>
      detail == null || detail!.isEmpty ? message : '$message ($detail)';
}

/// Runs [work] in a new isolate, forwarding its progress (0…1). [onIsolate]
/// receives the isolate so a caller can kill it to cancel.
///
/// [work] is copied into the isolate together with everything its scope
/// captures, so build it in a top-level function that takes only the data it
/// needs (see [_partJob], [_aiJob]). A closure written inline next to UI
/// callbacks would drag the page's state along, which can't be sent.
Future<T> runIsolate<T>(
  T Function(void Function(double) progress) work, {
  void Function(double)? onProgress,
  void Function(Isolate)? onIsolate,
}) async {
  final port = ReceivePort();
  final done = Completer<T>();
  port.listen((m) {
    if (m is double) {
      onProgress?.call(m);
    } else if (m is List && m.length == 1 && m[0] == 'cancelled') {
      if (!done.isCompleted) done.completeError(Cancelled());
    } else if (m is List && m.length >= 2) {
      if (m[0] == 'ok') {
        done.complete(m[1] as T);
      } else {
        done.completeError(
          StudioException(
            '${m[1]}',
            detail: m.length > 3 ? m[3] as String? : null,
          )..stack = m.length > 2 ? m[2] as String? : null,
        );
      }
    } else if (m == null && !done.isCompleted) {
      done.completeError(Cancelled());
    }
  });
  try {
    final iso =
        await Isolate.spawn<(SendPort, T Function(void Function(double)))>(
          _entry<T>,
          (port.sendPort, work),
          onExit: port.sendPort,
        );
    onIsolate?.call(iso);
    return await done.future;
  } finally {
    port.close();
  }
}

void _entry<T>((SendPort, T Function(void Function(double))) a) {
  final (send, work) = a;
  var last = -1.0;
  try {
    final r = work((f) {
      // at most ~100 messages per job
      if (f - last >= 0.01 || f >= 1) {
        last = f;
        send.send(f);
      }
    });
    // hands the result over without copying it (stems are large)
    Isolate.exit(send, ['ok', r]);
  } on Cancelled {
    send.send(['cancelled']);
  } catch (e, st) {
    send.send([
      'err',
      e is StudioException ? e.message : '$e',
      '$st',
      if (e is StudioException) e.detail,
    ]);
  }
}

/// Decodes a whole file to stereo float channels (read only); also says
/// which decoder read it.
(int, List<Float32List>, String) decodeStereo(
  String path, {
  double maxSeconds = 15 * 60,
}) {
  if (!File(path).existsSync()) {
    throw StudioException(
      'This song’s file can’t be found (moved or on a drive that isn’t connected).',
    );
  }
  final PcmReader r;
  try {
    r = openPcm(path);
  } on Object catch (e) {
    throw StudioException('This file can’t be decoded here.', detail: '$e');
  }
  try {
    final sr = r.sampleRate, ch = r.channels;
    final maxFrames = (maxSeconds * sr).round();
    var cap = sr * 60 * 4;
    var l = Float32List(cap), rt = Float32List(cap);
    var n = 0;
    for (var block = r.read(); block != null; block = r.read()) {
      final frames = block.length ~/ ch;
      if (n + frames > maxFrames) {
        throw StudioException(
          'Songs longer than 15 minutes aren’t supported here.',
        );
      }
      if (n + frames > cap) {
        cap = math.max(cap * 2, n + frames);
        l = Float32List(cap)..setRange(0, n, l);
        rt = Float32List(cap)..setRange(0, n, rt);
      }
      for (var i = 0; i < frames; i++) {
        l[n + i] = block[i * ch];
        rt[n + i] = ch > 1 ? block[i * ch + 1] : block[i * ch];
      }
      n += frames;
    }
    if (n == 0) throw StudioException('This file has no audio.');
    return (
      sr,
      [
        Float32List.fromList(Float32List.sublistView(l, 0, n)),
        Float32List.fromList(Float32List.sublistView(rt, 0, n)),
      ],
      '${r.runtimeType}',
    );
  } on DecodeException catch (e) {
    throw StudioException('This file can’t be decoded here.', detail: '$e');
  } finally {
    r.close();
  }
}

class StudioEngine {
  StudioEngine({int? cores})
    : workers =
          cores ?? math.max(2, math.min(6, Platform.numberOfProcessors - 1));
  final int workers;
  static const keep = 8;
  final songs = <String, Loaded>{};

  /// The installed Pro Stems AI model file, or null.
  String? aiModel;

  /// Where the last AI run happened: 'gpu' (DirectML) or 'cpu'.
  String? aiDevice;

  /// Set to 1 to stop the running AI split after its current segment (the
  /// job then closes the model itself, freeing ONNX Runtime's memory).
  ffi.Pointer<ffi.Int32>? _aiCancel;

  Future<Loaded> load(SongRef song) async {
    final hit = songs.remove(song.id);
    if (hit != null) {
      songs[song.id] = hit; // most recently used last
      return hit;
    }
    final path = song.path, sw = Stopwatch()..start();
    final (int, List<Float32List>, String) d;
    try {
      d = await Isolate.run(() => decodeStereo(path));
    } on Object catch (e, st) {
      DiagLog.error('studio', 'decoding $path failed: $e', st);
      rethrow;
    }
    final (sr, mix, decoder) = d;
    DiagLog.info(
      'studio',
      'decoded $path with $decoder: ${mix[0].length / sr} s at $sr Hz '
          'in ${sw.elapsedMilliseconds} ms',
    );
    final l = Loaded(song, sr, mix);
    songs[song.id] = l;
    while (songs.length > keep) {
      songs.remove(songs.keys.first);
    }
    return l;
  }

  Future<Analysis> analyse(Loaded l) async {
    if (l.analysis != null) return l.analysis!;
    final m = mono(l.mix), sr = l.sampleRate, bpm = l.song.bpm;
    l.analysis = await Isolate.run(() {
      final r = rhythm(m, sr, bpm);
      return Analysis(r.bpm, r.firstBeat, r.key, detectChords(m, sr));
    });
    return l.analysis!;
  }

  void cancelAi() {
    final c = _aiCancel;
    if (c != null) c.value = 1;
  }

  Future<Stems> _separateAi(
    Loaded l,
    String model,
    void Function(double)? onProgress,
  ) async {
    final cancel = calloc<ffi.Int32>();
    _aiCancel = cancel;
    final (Stems, String) r;
    try {
      r = await runIsolate<(Stems, String)>(
        _aiJob(l.mix, l.sampleRate, model, cancel.address),
        onProgress: onProgress,
      );
    } finally {
      // the isolate has finished with the flag once it has answered
      if (identical(_aiCancel, cancel)) _aiCancel = null;
      calloc.free(cancel);
    }
    final (out, device) = r;
    aiDevice = device;
    return {
      'vocals': out['vocals']!,
      'drums': out['drums']!,
      'bass': out['bass']!,
      'melodies': out['other']!,
    };
  }

  /// Four stems: with the AI model when [method] is 'ai' and the pack is
  /// installed (falling back to the built-in splitter if it can't run),
  /// otherwise with signal processing on every core.
  Future<Stems> separate(
    Loaded l, {
    void Function(double)? onProgress,
    String? method,
  }) async {
    method ??= aiModel != null ? 'ai' : 'fast';
    final model = aiModel;
    if (method == 'ai' && model != null) {
      if (l.aiStems == null) {
        try {
          final sw = Stopwatch()..start();
          l.aiStems = await _separateAi(l, model, onProgress);
          DiagLog.info(
            'studio',
            'AI split of ${l.durationSec.toStringAsFixed(1)} s on $aiDevice '
                'in ${sw.elapsedMilliseconds} ms',
          );
        } on Cancelled {
          rethrow;
        } catch (e, st) {
          DiagLog.error(
            'studio',
            'AI split failed, using Fast: $e',
            e is StudioException && e.stack != null
                ? StackTrace.fromString(e.stack!)
                : st,
          );
          aiDevice = null;
          l.stems = await separate(l, onProgress: onProgress, method: 'fast');
          l.stemsBy = 'fast';
          throw StudioException(
            "The AI model couldn't run here ($e); used the built-in splitter instead.",
            fallback: true,
          );
        }
      }
      l.stems = l.aiStems;
      l.stemsBy = 'ai';
      return l.stems!;
    }
    if (l.fastStems != null) {
      l.stems = l.fastStems;
      l.stemsBy = 'fast';
      return l.stems!;
    }
    final len = l.mix[0].length, sr = l.sampleRate;
    final plans = planParts(len, workers), sw = Stopwatch()..start();
    final prog = List.filled(plans.length, 0.0);
    final List<Part> parts;
    try {
      parts = await Future.wait([
        for (var i = 0; i < plans.length; i++)
          () {
            final p = plans[i];
            final ch = [
              Float32List.fromList(
                Float32List.sublistView(l.mix[0], p.inStart, p.inEnd),
              ),
              Float32List.fromList(
                Float32List.sublistView(l.mix[1], p.inStart, p.inEnd),
              ),
            ];
            return runIsolate<Part>(
              _partJob(ch, p.inStart, len, sr, p.f0, p.f1),
              onProgress: (f) {
                prog[i] = f;
                onProgress?.call(prog.reduce((a, b) => a + b) / prog.length);
              },
            );
          }(),
      ]);
    } on Object catch (e, st) {
      DiagLog.error('studio', 'Fast split failed: $e', st);
      rethrow;
    }
    l.stems = mergeParts(parts, len);
    DiagLog.info(
      'studio',
      'Fast split of ${l.durationSec.toStringAsFixed(1)} s on '
          '${plans.length} isolates in ${sw.elapsedMilliseconds} ms',
    );
    l.fastStems = l.stems;
    l.stemsBy = 'fast';
    return l.stems!;
  }

  /// A MIDI file with a track each for bass, melody, vocal melody, chords and drums.
  Future<(Uint8List, List<(String, int)>)> midi(Loaded l) async {
    final stems = await separate(l, method: l.stemsBy);
    final a = await analyse(l);
    final sr = l.sampleRate, bpm = a.bpm;
    final bass = mono(stems['bass']!),
        mel = mono(stems['melodies']!),
        voc = mono(stems['vocals']!),
        drums = mono(stems['drums']!);
    final chords = [
      for (final c in a.chords) (c.start, c.end, c.root, c.quality),
    ];
    return Isolate.run(() {
      final tracks = [
        MidiTrack(
          'Bass',
          0,
          transcribePitched(bass, sr, minHz: 30, maxHz: 350),
          33,
        ),
        MidiTrack(
          'Melody',
          1,
          transcribePitched(mel, sr, minHz: 120, maxHz: 1400),
          80,
        ),
        MidiTrack(
          'Vocal melody',
          2,
          transcribePitched(voc, sr, minHz: 80, maxHz: 1100),
          53,
        ),
        if (chords.isNotEmpty) MidiTrack('Chords', 3, chordNotes(chords), 0),
        MidiTrack('Drums', 9, transcribeDrums(drums, sr)),
      ];
      return (
        writeMidi(tracks, bpm == 0 ? 120 : bpm),
        [for (final t in tracks) (t.name, t.notes.length)],
      );
    });
  }

  // ---- remix

  final remixSources = <String, Source>{};

  Future<Source> remixSource(Loaded l, {required bool withStems}) async {
    final a = await analyse(l);
    final stems = withStems ? await separate(l, method: l.stemsBy) : null;
    final src = Source(
      id: l.song.id,
      name: l.song.title,
      sampleRate: l.sampleRate,
      layers: {'mix': l.mix, ...?stems},
      bpm: a.bpm == 0 ? 120 : a.bpm,
      firstBeat: a.firstBeat,
      tonic: a.key.tonic,
      mode: a.key.mode,
      keyShort: a.key.short,
      durationSec: l.durationSec,
    );
    remixSources[src.id] = src;
    return src;
  }

  /// Renders [project] in an isolate (only the sources it uses are copied).
  Future<Rendered> render(
    Project project,
    int sampleRate, {
    bool withTracks = false,
  }) {
    final used = {
      for (final t in project.tracks)
        for (final c in t.clips) c.sourceId,
    };
    final layers = {
      for (final t in project.tracks)
        for (final c in t.clips) '${c.sourceId}|${c.layer}',
    };
    final srcs = <String, Source>{
      for (final id in used)
        if (remixSources[id] != null)
          id: () {
            final s = remixSources[id]!;
            return Source(
              id: s.id,
              name: s.name,
              sampleRate: s.sampleRate,
              layers: {
                for (final e in s.layers.entries)
                  if (layers.contains('$id|${e.key}')) e.key: e.value,
              },
              bpm: s.bpm,
              firstBeat: s.firstBeat,
              tonic: s.tonic,
              mode: s.mode,
              keyShort: s.keyShort,
              durationSec: s.durationSec,
            );
          }(),
    };
    return Isolate.run(
      _renderJob(project, srcs, sampleRate, withTracks: withTracks),
    );
  }
}

// Isolate jobs. Each is built in its own top-level scope so the closure sent
// to the isolate captures only its arguments, never the engine or a page.

(Stems, String) Function(void Function(double)) _aiJob(
  List<Float32List> mix,
  int sr,
  String model,
  int cancelAddress,
) => (progress) {
  final cancel = ffi.Pointer<ffi.Int32>.fromAddress(cancelAddress);
  final m = HtDemucs.open(model);
  try {
    return (
      separateAi(
        mix,
        sr,
        m.run,
        onProgress: (d, t) {
          if (cancel.value != 0) throw Cancelled();
          progress(d / t);
        },
      ),
      m.device,
    );
  } finally {
    m.close();
  }
};

Part Function(void Function(double)) _partJob(
  List<Float32List> ch,
  int start,
  int len,
  int sr,
  int f0,
  int f1,
) =>
    (progress) =>
        separatePart(ch, start, len, sr, f0, f1, onProgress: progress);

Rendered Function() _renderJob(
  Project project,
  Map<String, Source> srcs,
  int sampleRate, {
  required bool withTracks,
}) =>
    () => renderProject(project, srcs, sampleRate, withTracks: withTracks);
