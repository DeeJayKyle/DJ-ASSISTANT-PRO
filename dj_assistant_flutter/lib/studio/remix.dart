import 'dart:math' as math;
import 'dart:typed_data';

import 'stretch.dart';

/// Remix projects: tracks of clips taken from songs or their stems, placed on a
/// beat grid. The project has one tempo and key; every clip is time-stretched
/// and pitch-shifted to match, so the DJ only makes the creative choices.
/// Layers: 'mix' or a stem name.
class Source {
  Source({
    required this.id,
    required this.name,
    required this.sampleRate,
    required this.layers,
    required this.bpm,
    required this.firstBeat,
    required this.tonic,
    required this.mode,
    required this.keyShort,
    required this.durationSec,
  });
  final String id, name, mode, keyShort;
  final int sampleRate, tonic;
  final Map<String, List<Float32List>> layers;
  final double bpm, firstBeat, durationSec;
}

class Clip {
  const Clip({
    required this.id,
    required this.sourceId,
    required this.layer,
    required this.start,
    this.offset = 0,
    required this.length,
    this.loops = 1,
  });
  final String id, sourceId, layer;
  final int start, offset, length, loops;
  int get end => start + length * loops;
  Clip copyWith({
    String? id,
    int? start,
    int? offset,
    int? length,
    int? loops,
  }) => Clip(
    id: id ?? this.id,
    sourceId: sourceId,
    layer: layer,
    start: start ?? this.start,
    offset: offset ?? this.offset,
    length: length ?? this.length,
    loops: loops ?? this.loops,
  );
}

class RTrack {
  const RTrack({
    required this.id,
    required this.name,
    this.gain = 0.8,
    this.pan = 0,
    this.mute = false,
    this.solo = false,
    required this.clips,
  });
  final String id, name;
  final double gain, pan;
  final bool mute, solo;
  final List<Clip> clips;
  RTrack copyWith({
    double? gain,
    double? pan,
    bool? mute,
    bool? solo,
    List<Clip>? clips,
  }) => RTrack(
    id: id,
    name: name,
    gain: gain ?? this.gain,
    pan: pan ?? this.pan,
    mute: mute ?? this.mute,
    solo: solo ?? this.solo,
    clips: clips ?? this.clips,
  );
}

class Project {
  const Project({
    this.name = 'My Remix',
    this.bpm = 120,
    this.tonic = 9,
    this.mode = 'minor',
    this.tracks = const [],
  });
  final String name, mode;
  final double bpm;
  final int tonic;
  final List<RTrack> tracks;
  Project copyWith({
    String? name,
    double? bpm,
    int? tonic,
    String? mode,
    List<RTrack>? tracks,
  }) => Project(
    name: name ?? this.name,
    bpm: bpm ?? this.bpm,
    tonic: tonic ?? this.tonic,
    mode: mode ?? this.mode,
    tracks: tracks ?? this.tracks,
  );
}

var _seq = 0;
String uid(String p) =>
    '$p${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${(_seq++).toRadixString(36)}';

/// Semitones to move a source into the project key (minor ↔ major goes via the
/// relative key).
int keyShift(int srcTonic, String srcMode, int tonic, String mode) {
  var target = tonic;
  if (srcMode != mode) {
    target = mode == 'major' ? (tonic + 9) % 12 : (tonic + 3) % 12;
  }
  return semitoneShift(srcTonic, target);
}

/// Beats in a source after its first beat.
int sourceBeats(Source s) =>
    math.max(1, ((s.durationSec - s.firstBeat) * s.bpm / 60).floor());

RTrack newTrackFor(Source source, String layer) {
  final beats = math.min(sourceBeats(source), 64);
  return RTrack(
    id: uid('t'),
    name: '${source.name}${layer == 'mix' ? '' : ' · $layer'}',
    clips: [
      Clip(
        id: uid('c'),
        sourceId: source.id,
        layer: layer,
        start: 0,
        length: beats,
      ),
    ],
  );
}

int projectBeats(Project p) => [
  16,
  for (final t in p.tracks)
    for (final c in t.clips) c.end,
].reduce(math.max);

final _cache = <String, List<Float32List>>{};
void clearRenderCache() => _cache.clear();

List<Float32List>? _clipAudio(Clip clip, Source src, Project project) {
  final ch = src.layers[clip.layer];
  if (ch == null || ch.isEmpty) return null;
  final speed = project.bpm / (src.bpm == 0 ? project.bpm : src.bpm);
  final semis = keyShift(src.tonic, src.mode, project.tonic, project.mode);
  final key =
      '${src.id}|${clip.layer}|${clip.offset}|${clip.length}|${speed.toStringAsFixed(5)}|$semis';
  final hit = _cache[key];
  if (hit != null) return hit;
  final a = math.max(
    0,
    ((src.firstBeat + clip.offset * 60 / src.bpm) * src.sampleRate).round(),
  );
  final b = math.min(
    ch[0].length,
    a + (clip.length * 60 / src.bpm * src.sampleRate).round(),
  );
  if (b <= a) return null;
  final seg = [for (final c in ch) Float32List.sublistView(c, a, b)];
  final out = retune(seg, speed, semis.toDouble());
  _cache[key] = out;
  return out;
}

class Rendered {
  Rendered(this.mix, this.tracks);
  final List<Float32List> mix;
  final Map<String, List<Float32List>> tracks;
}

/// Renders the whole project (and each track on its own) at [sampleRate].
Rendered renderProject(
  Project project,
  Map<String, Source> sources,
  int sampleRate, {
  bool withTracks = false,
}) {
  final beatSec = 60 / project.bpm;
  final total =
      (projectBeats(project) * beatSec * sampleRate).ceil() + sampleRate;
  final mix = [Float32List(total), Float32List(total)];
  final tracks = <String, List<Float32List>>{};
  final soloed = project.tracks.any((t) => t.solo);
  for (final t in project.tracks) {
    final tl = [Float32List(total), Float32List(total)];
    for (final c in t.clips) {
      final src = sources[c.sourceId];
      if (src == null) continue;
      final audio = _clipAudio(c, src, project);
      if (audio == null) continue;
      final loopLen = (c.length * beatSec * sampleRate).round();
      for (var rep = 0; rep < math.max(1, c.loops); rep++) {
        final at = ((c.start + rep * c.length) * beatSec * sampleRate).round();
        final n = math.min(loopLen, math.min(audio[0].length, total - at));
        if (n <= 0) continue;
        for (var chn = 0; chn < 2; chn++) {
          final x = chn < audio.length ? audio[chn] : audio[0];
          final y = tl[chn];
          for (var i = 0; i < n; i++) {
            y[at + i] += x[i];
          }
        }
        // tiny fades at clip edges avoid clicks
        final f = math.min(64, n >> 1);
        for (var i = 0; i < f; i++) {
          for (var chn = 0; chn < 2; chn++) {
            tl[chn][at + i] *= i / f;
            tl[chn][at + n - 1 - i] *= i / f;
          }
        }
      }
    }
    final angle = (t.pan + 1) * math.pi / 4;
    final gl = math.cos(angle) * math.sqrt2 * t.gain,
        gr = math.sin(angle) * math.sqrt2 * t.gain;
    for (var i = 0; i < total; i++) {
      tl[0][i] *= gl;
      tl[1][i] *= gr;
    }
    if (withTracks) tracks[t.id] = tl;
    final audible = soloed ? t.solo : !t.mute;
    if (audible) {
      for (var i = 0; i < total; i++) {
        mix[0][i] += tl[0][i];
        mix[1][i] += tl[1][i];
      }
    }
  }
  // soft limit so stacked tracks don't clip
  for (final c in mix) {
    for (var i = 0; i < c.length; i++) {
      final x = c[i];
      if (x.abs() >= 0.8) {
        c[i] = x.sign * (0.8 + 0.2 * _tanh((x.abs() - 0.8) / 0.2));
      }
    }
  }
  return Rendered(mix, tracks);
}

double _tanh(double x) {
  if (x > 20) return 1;
  final e = math.exp(2 * x);
  return (e - 1) / (e + 1);
}
