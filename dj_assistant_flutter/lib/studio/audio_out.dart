import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_soloud/flutter_soloud.dart';

import '../core/diag_log.dart';
import '../ui/player.dart' show AudioEngine;
import 'biquad.dart';
import 'stretch.dart';

/// Plays interleaved stereo float audio that a [render] callback produces
/// block by block, through one SoLoud buffer stream. About [lead] seconds are
/// kept queued, so a change made in [render] is heard that much later.
class PcmStream {
  PcmStream(this.sampleRate, this.render, {this.lead = 0.12});
  final int sampleRate;
  final double lead;

  /// Fills `l[0..n)` and `r[0..n)` with the next block.
  final void Function(Float32List l, Float32List r, int n) render;

  static const block = 1024;
  AudioSource? _stream;
  SoundHandle? _handle;
  Timer? _timer;
  final _clock = Stopwatch();
  int _pushed = 0, _base = 0;
  final _l = Float32List(block), _r = Float32List(block);
  final _inter = Float32List(block * 2);
  SoLoud get _sl => SoLoud.instance;

  bool get running => _stream != null;

  /// Frames rendered so far that have been heard (an estimate from the clock).
  int get heardFrames =>
      _base +
      math.min(
        _pushed,
        (_clock.elapsedMicroseconds * sampleRate / 1e6).floor(),
      );

  /// Starts the sound card; false (and logged) when there is no audio device.
  Future<bool> start() async {
    if (_stream != null) return true;
    if (!await AudioEngine.instance.ready()) return false;
    try {
      _stream = _sl.setBufferStream(
        maxBufferSizeDuration: const Duration(minutes: 10),
        bufferingType: BufferingType.released,
        bufferingTimeNeeds: 0.05,
        sampleRate: sampleRate,
        channels: Channels.stereo,
        format: BufferType.f32le,
      );
      _pushed = 0;
      _base = 0;
      _clock
        ..reset()
        ..start();
      _fill();
      _handle = _sl.play(_stream!);
      _timer = Timer.periodic(const Duration(milliseconds: 10), (_) => _fill());
      return true;
    } on Object catch (e, st) {
      DiagLog.error('audio', 'could not start the audio stream: $e', st);
      await stop();
      return false;
    }
  }

  void _fill() {
    final s = _stream;
    if (s == null) return;
    // rotate the stream before it fills up (released data still counts)
    if (_pushed > sampleRate * 9 * 60) {
      final heard = heardFrames;
      unawaited(
        stop().then((_) async {
          await start();
          _base = heard;
        }),
      );
      return;
    }
    while (_pushed / sampleRate - _clock.elapsedMicroseconds / 1e6 < lead) {
      render(_l, _r, block);
      for (var i = 0; i < block; i++) {
        _inter[i * 2] = _l[i].clamp(-1, 1);
        _inter[i * 2 + 1] = _r[i].clamp(-1, 1);
      }
      try {
        _sl.addAudioDataStream(
          s,
          Uint8List.fromList(_inter.buffer.asUint8List()),
        );
      } on Object catch (e, st) {
        DiagLog.error('audio', 'the audio stream stopped: $e', st);
        unawaited(stop());
        return;
      }
      _pushed += block;
    }
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    final h = _handle, s = _stream;
    _handle = null;
    _stream = null;
    _clock.stop();
    try {
      if (h != null && _sl.getIsValidVoiceHandle(h)) await _sl.stop(h);
      if (s != null) await _sl.disposeSource(s);
    } on Object {
      // the device went away
    }
  }
}

/// Several stereo layers (stems) mixed in sync, each with its own volume.
/// The mix is rendered in Dart and streamed, so nothing is encoded or
/// copied when a song loads, and solo, mute and volume apply at once
/// (about a tenth of a second later) without reloading.
class LayerMix {
  LayerMix(this.layers, this.sampleRate)
    : volumes = List.filled(layers.length, 1),
      length = layers.isEmpty ? 0 : layers[0][0].length;
  final List<List<Float32List>> layers;
  final int sampleRate, length;
  List<double> volumes;

  /// Next frame to render.
  int pos = 0;
  bool get atEnd => pos >= length;

  /// Mixes the next [n] frames into [l], [r] (silence after the end).
  void render(Float32List l, Float32List r, int n) {
    l.fillRange(0, n, 0);
    r.fillRange(0, n, 0);
    final m = math.max(0, math.min(n, length - pos));
    for (var k = 0; k < layers.length; k++) {
      final g = k < volumes.length ? volumes[k] : 0.0;
      if (g == 0) continue;
      final a = layers[k][0], b = layers[k].length > 1 ? layers[k][1] : a;
      for (var i = 0; i < m; i++) {
        l[i] += a[pos + i] * g;
        r[i] += b[pos + i] * g;
      }
    }
    pos += n;
  }
}

/// Plays a [LayerMix] (the Stems page, Remix previews).
class LayerPlayer {
  LayerMix? _mix;
  PcmStream? _out;
  int _startFrame = 0;
  double _pausedAt = 0;

  bool get loaded => _mix != null;
  bool get playing => _out?.running ?? false;

  /// Seconds into the audio.
  double get position {
    final m = _mix, o = _out;
    if (m == null) return 0;
    if (o == null || !o.running) return _pausedAt;
    return math.min(m.length, _startFrame + o.heardFrames) / m.sampleRate;
  }

  /// Prepares [layers]; false when there is no audio device (logged).
  Future<bool> load(List<List<Float32List>> layers, int sampleRate) async {
    await dispose();
    _mix = LayerMix(layers, sampleRate);
    return AudioEngine.instance.ready();
  }

  /// Starts at [from] seconds; false when the sound card can't be used.
  Future<bool> play(double from, List<double> volumes) async {
    await _stopOut();
    final m = _mix;
    if (m == null) return false;
    m
      ..volumes = List.of(volumes)
      ..pos = (from * m.sampleRate).round().clamp(0, m.length);
    _startFrame = m.pos;
    final o = PcmStream(m.sampleRate, m.render);
    _out = o;
    return o.start();
  }

  void setVolumes(List<double> v) => _mix?.volumes = List.of(v);

  void pause() {
    _pausedAt = position;
    unawaited(_stopOut());
  }

  void stop() => unawaited(_stopOut());

  Future<void> _stopOut() async {
    final o = _out;
    _out = null;
    await o?.stop();
  }

  bool get ended {
    final m = _mix, o = _out;
    return m != null &&
        o != null &&
        o.running &&
        _startFrame + o.heardFrames >= m.length;
  }

  double get duration => _mix == null ? 0 : _mix!.length / _mix!.sampleRate;

  Future<void> dispose() async {
    await _stopOut();
    _mix = null;
    _pausedAt = 0;
  }
}

/// One realtime deck: a [DeckReader] (tempo / key / stems / loops) and its
/// EQ + filter strip.
class Deck {
  DeckReader? reader;
  int sampleRate = 44100;
  final strip = DeckStrip();
  double volume = 0.9, channelGain = 1;
  double tempo = 1, semis = 0;

  void load(List<List<Float32List>> layers, int sr) {
    final was = reader;
    reader = DeckReader(layers)
      ..playing = false
      ..gains.fillRange(0, layers.length, 1);
    sampleRate = sr;
    if (was != null) {
      reader!.loop = was.loop;
    }
  }

  void configure(int outRate) {
    final r = reader;
    if (r == null) return;
    final ratio = sampleRate / outRate;
    r.rate = tempo * ratio;
    r.pitch = math.pow(2, semis / 12).toDouble() * ratio;
  }

  /// Seconds into the song.
  double get time => reader?.time(sampleRate) ?? 0;

  void seek(double sec) => reader?.seek(sec * sampleRate);
}

/// Mixes the two decks in Dart and streams the result to the sound card.
/// ~120 ms of audio is kept queued; parameters apply to the next block.
class DeckMixer {
  DeckMixer();
  static const outRate = 44100;
  final decks = [Deck(), Deck()];
  double crossfade = 0.5;
  PcmStream? _out;
  final _dl = Float32List(PcmStream.block), _dr = Float32List(PcmStream.block);
  bool _starting = false;

  bool get anyPlaying => decks.any((d) => d.reader?.playing ?? false);

  /// Starts streaming when a deck plays; stops when both are paused.
  Future<void> update() async {
    if (anyPlaying && _out == null && !_starting) {
      _starting = true;
      try {
        final o = PcmStream(outRate, _mix);
        if (await o.start()) _out = o;
      } finally {
        _starting = false;
      }
    } else if (!anyPlaying && _out != null) {
      await _close();
    }
  }

  void _mix(Float32List l, Float32List r, int n) {
    l.fillRange(0, n, 0);
    r.fillRange(0, n, 0);
    for (var i = 0; i < 2; i++) {
      final d = decks[i];
      final rd = d.reader;
      if (rd == null || !rd.playing) continue;
      d.configure(outRate);
      rd.render([_dl, _dr], n);
      d.strip.process(_dl, _dr, n, outRate);
      final x = i == 0 ? 1 - crossfade : crossfade;
      final g = math.sin(x * math.pi / 2) * math.sqrt2 * 0.7 * d.volume;
      for (var k = 0; k < n; k++) {
        l[k] += _dl[k] * g;
        r[k] += _dr[k] * g;
      }
      if (rd.pos >= rd.length) rd.playing = false;
    }
  }

  Future<void> _close() async {
    final o = _out;
    _out = null;
    await o?.stop();
  }

  Future<void> dispose() async {
    for (final d in decks) {
      d.reader?.playing = false;
    }
    await _close();
  }
}
