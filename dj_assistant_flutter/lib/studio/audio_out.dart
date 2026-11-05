import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_soloud/flutter_soloud.dart';

import '../ui/player.dart' show AudioEngine;
import 'biquad.dart';
import 'dsp.dart' show encodeWav;
import 'stretch.dart';

/// Several stereo layers (stems) played in sync, each with its own volume.
class LayerPlayer {
  final _sources = <AudioSource>[];
  final _handles = <SoundHandle>[];
  double _duration = 0;
  SoLoud get _sl => SoLoud.instance;

  bool get loaded => _sources.isNotEmpty;
  bool get playing =>
      _handles.isNotEmpty &&
      _sl.getIsValidVoiceHandle(_handles.first) &&
      !_sl.getPause(_handles.first);

  /// Seconds into the audio.
  double get position {
    if (_handles.isEmpty || !_sl.getIsValidVoiceHandle(_handles.first)) {
      return _pausedAt;
    }
    return _sl.getPosition(_handles.first).inMicroseconds / 1e6;
  }

  double _pausedAt = 0;

  Future<bool> load(List<List<Float32List>> layers, int sampleRate) async {
    await dispose();
    if (!await AudioEngine.instance.ready()) return false;
    var i = 0;
    for (final l in layers) {
      _sources.add(
        await _sl.loadMem(
          'studio-layer-${i++}-${DateTime.now().microsecondsSinceEpoch}.wav',
          encodeWav(l, sampleRate),
        ),
      );
    }
    _duration = layers.isEmpty ? 0 : layers[0][0].length / sampleRate;
    return true;
  }

  void play(double from, List<double> volumes) {
    stop();
    if (_sources.isEmpty) return;
    for (var i = 0; i < _sources.length; i++) {
      final h = _sl.play(_sources[i], paused: true, volume: volumes[i]);
      _sl.seek(h, Duration(microseconds: (from * 1e6).round()));
      _handles.add(h);
    }
    for (final h in _handles) {
      _sl.setPause(h, false);
    }
  }

  void setVolumes(List<double> v) {
    for (var i = 0; i < _handles.length && i < v.length; i++) {
      if (_sl.getIsValidVoiceHandle(_handles[i])) {
        _sl.setVolume(_handles[i], v[i]);
      }
    }
  }

  void pause() {
    _pausedAt = position;
    stop();
  }

  void stop() {
    for (final h in _handles) {
      if (_sl.getIsValidVoiceHandle(h)) unawaited(_sl.stop(h));
    }
    _handles.clear();
  }

  bool get ended =>
      _handles.isNotEmpty && !_sl.getIsValidVoiceHandle(_handles.first);
  double get duration => _duration;

  Future<void> dispose() async {
    stop();
    for (final s in _sources) {
      await _sl.disposeSource(s);
    }
    _sources.clear();
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
  static const _block = 1024;
  static const _lead = 0.12;
  final decks = [Deck(), Deck()];
  double crossfade = 0.5;
  AudioSource? _stream;
  SoundHandle? _handle;
  Timer? _timer;
  final _clock = Stopwatch();
  int _pushed = 0;
  final _l = Float32List(_block), _r = Float32List(_block);
  final _dl = Float32List(_block), _dr = Float32List(_block);
  bool _starting = false;
  SoLoud get _sl => SoLoud.instance;

  bool get anyPlaying => decks.any((d) => d.reader?.playing ?? false);

  /// Starts streaming when a deck plays; stops when both are paused.
  Future<void> update() async {
    if (anyPlaying && _stream == null && !_starting) {
      _starting = true;
      try {
        if (!await AudioEngine.instance.ready()) return;
        _stream = _sl.setBufferStream(
          maxBufferSizeDuration: const Duration(minutes: 10),
          bufferingType: BufferingType.released,
          bufferingTimeNeeds: 0.05,
          sampleRate: outRate,
          channels: Channels.stereo,
          format: BufferType.f32le,
        );
        _pushed = 0;
        _clock
          ..reset()
          ..start();
        _fill();
        _handle = _sl.play(_stream!);
        _timer = Timer.periodic(
          const Duration(milliseconds: 10),
          (_) => _fill(),
        );
      } on Object {
        await _close();
      } finally {
        _starting = false;
      }
    } else if (!anyPlaying && _stream != null) {
      await _close();
    }
  }

  void _fill() {
    final s = _stream;
    if (s == null) return;
    // rotate the stream before it fills up (released data still counts)
    if (_pushed > outRate * 9 * 60) {
      unawaited(_close().then((_) => update()));
      return;
    }
    while (_pushed / outRate - _clock.elapsedMicroseconds / 1e6 < _lead) {
      _mix();
      final inter = Float32List(_block * 2);
      for (var i = 0; i < _block; i++) {
        inter[i * 2] = _l[i];
        inter[i * 2 + 1] = _r[i];
      }
      try {
        _sl.addAudioDataStream(s, inter.buffer.asUint8List());
      } on Object {
        unawaited(_close());
        return;
      }
      _pushed += _block;
    }
  }

  void _mix() {
    _l.fillRange(0, _block, 0);
    _r.fillRange(0, _block, 0);
    for (var i = 0; i < 2; i++) {
      final d = decks[i];
      final r = d.reader;
      if (r == null || !r.playing) continue;
      d.configure(outRate);
      r.render([_dl, _dr], _block);
      d.strip.process(_dl, _dr, _block, outRate);
      final x = i == 0 ? 1 - crossfade : crossfade;
      final g = math.sin(x * math.pi / 2) * math.sqrt2 * 0.7 * d.volume;
      for (var k = 0; k < _block; k++) {
        _l[k] += _dl[k] * g;
        _r[k] += _dr[k] * g;
      }
      if (r.pos >= r.length) r.playing = false;
    }
    for (var k = 0; k < _block; k++) {
      _l[k] = _l[k].clamp(-1, 1);
      _r[k] = _r[k].clamp(-1, 1);
    }
  }

  Future<void> _close() async {
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

  Future<void> dispose() async {
    for (final d in decks) {
      d.reader?.playing = false;
    }
    await _close();
  }
}
