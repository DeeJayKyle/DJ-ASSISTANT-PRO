import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/diag_log.dart';
import '../../studio/audio_out.dart';
import '../../studio/dsp.dart' show overview;
import '../../studio/engine.dart';
import '../../studio/remix.dart' show keyShift;
import '../../studio/stems.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets.dart' show EmptyState;
import 'common.dart';

class _DeckState {
  SongRef? song;
  Loaded? loaded;
  Float32List? peaks;
  bool stems = false;
  final gains = {for (final s in stemNames) s: 1.0};
  String? busy;
  double progress = 0;
  final cues = List<double?>.filled(4, null);
  int? loopBeats;
}

String _shiftedKey(int tonic, String mode, int semis) =>
    '${noteNames[((tonic + semis) % 12 + 12) % 12]}${mode == 'minor' ? 'm' : ''}';

/// Two decks with automatic beat matching, key changes, stem toggles, 3-band
/// EQ, filter sweeps, hot cues and beat loops; a crossfader in between.
class DjPage extends ConsumerStatefulWidget {
  const DjPage({super.key});
  @override
  ConsumerState<DjPage> createState() => _DjPageState();
}

class _DjPageState extends ConsumerState<DjPage> {
  final mixer = DeckMixer();
  final decks = [_DeckState(), _DeckState()];
  Timer? _tick;

  // Settings → Limits apply as soon as they change
  StudioEngine get engine =>
      ref.read(studioEngineProvider)
        ..maxMinutes = userLimit(ref, 'studio_minutes');

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(milliseconds: 60), (_) {
      if (!mounted) return;
      if (!mixer.anyPlaying) unawaited(mixer.update());
      setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    unawaited(mixer.dispose());
    super.dispose();
  }

  Deck deck(int i) => mixer.decks[i];
  bool playingOf(int i) => deck(i).reader?.playing ?? false;
  double bpmOf(int i) => (decks[i].loaded?.analysis?.bpm ?? 0) * deck(i).tempo;

  List<List<Float32List>> _layers(Loaded l, bool stems) =>
      stems && l.stems != null
      ? [for (final s in stemNames) l.stems![s]!]
      : [l.mix];

  void _applyGains(int i) {
    final r = deck(i).reader, d = decks[i];
    if (r == null) return;
    if (d.stems) {
      for (var k = 0; k < stemNames.length && k < r.gains.length; k++) {
        r.gains[k] = d.gains[stemNames[k]]!;
      }
    } else {
      r.gains.fillRange(0, r.gains.length, 1);
    }
  }

  Future<void> load(int i, SongRef song) async {
    final d = decks[i] = _DeckState()
      ..song = song
      ..busy = 'Loading…';
    deck(i).reader?.playing = false;
    setState(() {});
    try {
      final l = await engine.load(song);
      final a = await engine.analyse(l);
      if (!mounted || decks[i] != d) return;
      final dk = deck(i)
        ..load(_layers(l, false), l.sampleRate)
        ..semis = 0
        ..strip.eqLow = 0
        ..strip.eqMid = 0
        ..strip.eqHigh = 0
        ..strip.filter = 0;
      dk.reader!.loop = null;
      // Auto beat-match: a deck loaded while the other plays takes its tempo.
      final other = 1 - i;
      dk.tempo = decks[other].loaded != null && playingOf(other) && a.bpm > 0
          ? (bpmOf(other) / a.bpm).clamp(0.67, 1.5)
          : 1;
      dk.seek(a.firstBeat);
      setState(() {
        d
          ..loaded = l
          ..peaks = overview(l.mix, 700)
          ..busy = null;
      });
    } on Object catch (e, st) {
      DiagLog.error('dj', e, st);
      setState(() => d.busy = null);
      toast(errText(e), error: true);
    }
  }

  Future<void> toggleStems(int i) async {
    final d = decks[i], l = d.loaded;
    if (l == null) return;
    if (l.stems == null) {
      setState(() {
        d.busy = 'Separating stems…';
        d.progress = 0;
      });
      try {
        await engine.separate(
          l,
          onProgress: (p) {
            if (mounted) setState(() => d.progress = p);
          },
        );
        ref.read(splitSongsProvider.notifier).mark(l.song.id);
      } on Object catch (e, st) {
        DiagLog.error('dj', e, st);
        setState(() => d.busy = null);
        toast(errText(e), error: true);
        return;
      }
    }
    final dk = deck(i);
    final t = dk.time, playing = playingOf(i), loop = dk.reader?.loop;
    d.stems = !d.stems;
    dk.load(_layers(l, d.stems), l.sampleRate);
    dk.reader!.loop = loop;
    _applyGains(i);
    dk.seek(t);
    dk.reader!.playing = playing;
    setState(() => d.busy = null);
  }

  Future<void> playPause(int i) async {
    final r = deck(i).reader;
    if (r == null) return;
    r.playing = !r.playing;
    await mixer.update();
    setState(() {});
  }

  void cue(int i) => deck(i).seek(decks[i].loaded?.analysis?.firstBeat ?? 0);

  /// Match this deck's tempo to the other, then line up the beats.
  void sync(int i) {
    final a = decks[i].loaded?.analysis, b = decks[1 - i].loaded?.analysis;
    if (a == null || b == null || a.bpm == 0 || b.bpm == 0) return;
    final me = deck(i), other = deck(1 - i);
    me.tempo = b.bpm * other.tempo / a.bpm;
    if (playingOf(1 - i)) {
      final beatB = (other.time - b.firstBeat) / (60 / b.bpm);
      final fracB = beatB - beatB.floor();
      final beatA = (me.time - a.firstBeat) / (60 / a.bpm);
      me.seek(
        math.max(0, a.firstBeat + (beatA.floor() + fracB) * (60 / a.bpm)),
      );
    }
    setState(() {});
  }

  void matchKey(int i) {
    final me = decks[i].loaded?.analysis, other = decks[1 - i].loaded?.analysis;
    if (me == null || other == null) return;
    final k = other.key;
    final target = ((k.tonic + deck(1 - i).semis.round()) % 12 + 12) % 12;
    deck(i).semis = keyShift(
      me.key.tonic,
      me.key.mode,
      target,
      k.mode,
    ).toDouble();
    setState(() {});
  }

  /// Beat loops from the beat at or before the playhead.
  void setLoop(int i, int beats) {
    final d = decks[i], a = d.loaded?.analysis, r = deck(i).reader;
    if (a == null || r == null) return;
    if (d.loopBeats == beats || a.bpm == 0) {
      r.loop = null;
      setState(() => d.loopBeats = null);
      return;
    }
    final period = 60 / a.bpm, t = deck(i).time;
    final start = math.max(
      0.0,
      a.firstBeat + ((t - a.firstBeat) / period).floor() * period,
    );
    final sr = deck(i).sampleRate;
    r.loop = (start * sr, (start + beats * period) * sr);
    setState(() => d.loopBeats = beats);
  }

  void hotCue(int i, int n, {bool clear = false}) {
    final d = decks[i];
    if (clear) {
      setState(() => d.cues[n] = null);
    } else if (d.cues[n] == null) {
      setState(() => d.cues[n] = deck(i).time);
    } else {
      deck(i).seek(d.cues[n]!);
    }
  }

  Future<void> pick(int i) async {
    final song = await showDialog<SongRef>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Load deck ${i == 0 ? 'A' : 'B'}'),
        content: SizedBox(
          width: 520,
          child: SongPicker(
            onPick: (s) => Navigator.pop(ctx, s),
            label: 'Song for the deck',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
    if (song != null) await load(i, song);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(handoffProvider, (_, h) {
      if (h != null && h.page == 'dj') {
        unawaited(load(decks[0].song != null ? 1 : 0, h.song));
      }
    });
    final views = [for (var i = 0; i < 2; i++) _deckView(i)];
    return LayoutBuilder(
      builder: (context, box) {
        final narrow = box.maxWidth < 760;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (narrow) ...[views[0], const SizedBox(height: 10), views[1]],
            if (!narrow)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: views[0]),
                  const SizedBox(width: 10),
                  Expanded(child: views[1]),
                ],
              ),
            const SizedBox(height: 10),
            StudioPanel(
              child: Row(
                children: [
                  const Text('A'),
                  Expanded(
                    child: Semantics(
                      label: 'Crossfader',
                      child: Slider(
                        value: mixer.crossfade,
                        onChanged: (v) => setState(() => mixer.crossfade = v),
                      ),
                    ),
                  ),
                  const Text('B'),
                ],
              ),
            ),
            if (decks.every((d) => d.song == null))
              const EmptyState(
                icon: Icons.headphones_outlined,
                title: 'Load a song on each deck',
                message:
                    'Press Load a song on deck A and B. DJ Decks match the tempo '
                    'and beats for you, and each deck has EQ, a filter, hot cues, '
                    'loops, and Stems with a volume for each part.',
              ),
          ],
        );
      },
    );
  }

  Widget _deckView(int i) {
    final t = DjTokens.of(context);
    final d = decks[i], dk = deck(i), letter = i == 0 ? 'A' : 'B';
    final l = d.loaded, a = l?.analysis;
    final dur = l?.durationSec ?? 0;
    final playing = playingOf(i);
    final bpm = bpmOf(i);
    final other = decks[1 - i];
    final semis = dk.semis.round();
    final synced =
        a != null &&
        other.loaded?.analysis != null &&
        (bpm - bpmOf(1 - i)).abs() < 0.05;
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: playing ? t.accent : t.line),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                CircleAvatar(radius: 14, child: Text(letter)),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        d.song?.title ?? 'Empty deck',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      if (d.song?.artist != null)
                        Text(
                          d.song!.artist!,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: t.faint,
                            fontSize: DjType.small,
                          ),
                        ),
                    ],
                  ),
                ),
                OutlinedButton(
                  onPressed: () => pick(i),
                  child: Text(d.song == null ? 'Load a song' : 'Change'),
                ),
              ],
            ),
            if (d.busy != null)
              StudioProgress(
                d.busy!,
                d.busy!.startsWith('Separating') ? d.progress : null,
              ),
            if (l != null && d.peaks != null) ...[
              const SizedBox(height: 8),
              WaveView(
                peaks: d.peaks!,
                progress: dur == 0 ? 0 : (dk.time / dur).clamp(0, 1),
                height: 64,
                onSeek: (f) => dk.seek(f * dur),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton(
                    onPressed: () => playPause(i),
                    child: Icon(
                      playing ? Icons.pause : Icons.play_arrow,
                      semanticLabel:
                          '${playing ? 'Pause' : 'Play'} deck $letter',
                    ),
                  ),
                  OutlinedButton(
                    onPressed: () => cue(i),
                    child: const Text('Cue'),
                  ),
                  chip(
                    'Sync',
                    synced,
                    other.loaded == null ? null : () => sync(i),
                  ),
                  Text('${fmtTime(dk.time)} / ${fmtTime(dur)}'),
                  Text(
                    '${bpm > 0 ? bpm.toStringAsFixed(1) : '—'} BPM',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  Text(
                    a == null
                        ? '—'
                        : '${_shiftedKey(a.key.tonic, a.key.mode, semis)}${semis != 0 ? ' (${semis > 0 ? '+' : ''}$semis st)' : ''}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ],
              ),
              Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Knob(
                    label: 'Tempo',
                    value: dk.tempo,
                    min: 0.84,
                    max: 1.16,
                    width: 220,
                    format: (v) => '${((v - 1) * 100).toStringAsFixed(1)}%',
                    onChanged: (v) => setState(() => dk.tempo = v),
                  ),
                  Text('Key', style: TextStyle(color: t.muted)),
                  IconButton(
                    tooltip: 'Key down',
                    onPressed: () =>
                        setState(() => dk.semis = math.max(-6, dk.semis - 1)),
                    icon: const Icon(Icons.remove),
                  ),
                  TextButton(
                    onPressed: () => setState(() => dk.semis = 0),
                    child: const Text('0'),
                  ),
                  IconButton(
                    tooltip: 'Key up',
                    onPressed: () =>
                        setState(() => dk.semis = math.min(6, dk.semis + 1)),
                    icon: const Icon(Icons.add),
                  ),
                  TextButton(
                    onPressed: other.loaded == null ? null : () => matchKey(i),
                    child: const Text('Match'),
                  ),
                  Knob(
                    label: 'Volume',
                    value: dk.volume,
                    min: 0,
                    max: 1.2,
                    onChanged: (v) => setState(() => dk.volume = v),
                  ),
                ],
              ),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text('Hot cues', style: TextStyle(color: t.muted)),
                  for (var n = 0; n < 4; n++)
                    GestureDetector(
                      onSecondaryTap: () => hotCue(i, n, clear: true),
                      onLongPress: () => hotCue(i, n, clear: true),
                      child: chip(
                        '${n + 1}',
                        d.cues[n] != null,
                        () => hotCue(i, n),
                        tooltip: d.cues[n] != null
                            ? 'Jump to ${fmtTime(d.cues[n]!)} (right-click to clear)'
                            : 'Set a cue here',
                      ),
                    ),
                  const SizedBox(width: 12),
                  Text('Loop', style: TextStyle(color: t.muted)),
                  for (final b in [1, 2, 4, 8])
                    chip('$b', d.loopBeats == b, () => setLoop(i, b)),
                ],
              ),
              Wrap(
                spacing: 8,
                children: [
                  for (final (band, label) in [
                    ('low', 'Low'),
                    ('mid', 'Mid'),
                    ('high', 'High'),
                  ])
                    GestureDetector(
                      onDoubleTap: () => setState(() => _setEq(dk, band, 0)),
                      child: Knob(
                        label: label,
                        value: _eq(dk, band),
                        min: -24,
                        max: 6,
                        width: 130,
                        format: (v) =>
                            '${v > 0 ? '+' : ''}${v.toStringAsFixed(0)} dB',
                        onChanged: (v) => setState(() => _setEq(dk, band, v)),
                      ),
                    ),
                  GestureDetector(
                    onDoubleTap: () => setState(() => dk.strip.filter = 0),
                    child: Knob(
                      label: 'Filter',
                      value: dk.strip.filter,
                      min: -1,
                      max: 1,
                      width: 200,
                      format: (v) => v < -0.02
                          ? 'low-pass'
                          : v > 0.02
                          ? 'high-pass'
                          : 'off',
                      onChanged: (v) => setState(() => dk.strip.filter = v),
                    ),
                  ),
                ],
              ),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  chip(
                    'Stems',
                    d.stems,
                    d.busy != null ? null : () => toggleStems(i),
                  ),
                  if (d.stems)
                    for (final s in stemNames)
                      chip(
                        s[0].toUpperCase() + s.substring(1),
                        d.gains[s]! > 0,
                        () {
                          d.gains[s] = d.gains[s]! > 0 ? 0 : 1;
                          _applyGains(i);
                          setState(() {});
                        },
                      ),
                  if (!d.stems)
                    Text(
                      'Turn on Stems to drop the vocals, drums, bass or melodies live.',
                      style: TextStyle(color: t.faint, fontSize: DjType.small),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  double _eq(Deck d, String band) => switch (band) {
    'low' => d.strip.eqLow,
    'mid' => d.strip.eqMid,
    _ => d.strip.eqHigh,
  };

  void _setEq(Deck d, String band, double v) {
    switch (band) {
      case 'low':
        d.strip.eqLow = v;
      case 'mid':
        d.strip.eqMid = v;
      default:
        d.strip.eqHigh = v;
    }
  }
}
