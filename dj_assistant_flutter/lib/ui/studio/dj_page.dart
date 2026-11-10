import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../analysis/beatgrid.dart';
import '../../core/diag_log.dart';
import '../../core/library.dart';
import '../../studio/audio_out.dart';
import '../../studio/dsp.dart' show overview;
import '../../studio/engine.dart';
import '../../studio/remix.dart' show keyShift;
import '../../studio/stems.dart';
import '../../studio/stems_cache.dart';
import '../format.dart';
import '../state.dart';
import '../theme.dart';
import 'common.dart';

/// Waveform detail: peaks per second of the scrolling waveforms.
const _pps = 100;

/// Seconds of real time shown across the scrolling waveforms.
const _window = 8.0;

class _DeckState {
  SongRef? song;
  Loaded? loaded;

  /// Whole-track overview (700 peaks) and scrolling detail ([_pps] per s).
  Float32List? peaks, detail;

  /// Scrolling detail per stem, once the deck has stems.
  Map<String, Float32List>? stemDetail;

  /// The track's beatgrid (Serato's or this app's), when it has one.
  BeatGrid? grid;
  bool stems = false;
  final gains = {for (final s in stemNames) s: 1.0};
  String? busy;
  double progress = 0;
  final cues = List<double?>.filled(8, null);
  int? loopBeats;
  String pads = 'cues'; // cues | loops | stems
}

String _shiftedKey(int tonic, String mode, int semis) =>
    '${noteNames[((tonic + semis) % 12 + 12) % 12]}${mode == 'minor' ? 'm' : ''}';

/// Colours for the four stems, from the app's own theme tokens.
Map<String, Color> stemColors(DjTokens t) => {
  'vocals': t.accent,
  'drums': t.warn,
  'bass': t.ok,
  'melodies': Color.lerp(t.accent, t.text, 0.55)!,
};

const _stemLabels = {
  'vocals': 'Vocals',
  'drums': 'Drums',
  'bass': 'Bass',
  'melodies': 'Melodies',
};

/// DJ Decks: the two decks' waveforms scroll side by side on one time scale
/// with their beatgrids, so beats line up visually when the decks are in
/// sync. Below them each deck has its transport, tempo, key and pads (hot
/// cues, loops, stems), with the mixer (EQ, filter, volume, crossfader) in
/// the middle and the library underneath for loading songs.
class DjPage extends ConsumerStatefulWidget {
  const DjPage({super.key});
  @override
  ConsumerState<DjPage> createState() => _DjPageState();
}

class _DjPageState extends ConsumerState<DjPage> {
  final mixer = DeckMixer();
  final decks = [_DeckState(), _DeckState()];
  Timer? _tick;

  // Settings → Studio and → Limits apply as soon as they change
  StudioEngine get engine =>
      applyStudioSettings(ref, ref.read(studioEngineProvider));

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(milliseconds: 40), (_) {
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
  double _beatSec(int i) {
    final b = decks[i].loaded?.analysis?.bpm ?? 0;
    return b > 0 ? 60 / b : 0;
  }

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

  /// The library's beatgrid for [song] (Serato's own or this app's).
  BeatGrid? _gridFor(SongRef song) {
    final id = int.tryParse(song.id);
    if (id == null) return null;
    try {
      return ref.read(sessionProvider).analysis.beatgridFor(id, song.path);
    } on Object {
      return null;
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
      var a = await engine.analyse(l);
      // A whole-file grid from the library places beat 1 better than the
      // quick look the Studio takes on its own.
      final grid = _gridFor(song);
      if (grid != null && grid.bpm > 0) {
        a = Analysis(grid.bpm, grid.firstBeatMs / 1000, a.key, a.chords);
        l.analysis = a;
      }
      final mix = l.mix, dur = l.durationSec;
      final (over, detail) = await Isolate.run(
        () => (
          overview(mix, 700),
          overview(mix, math.max(1, (dur * _pps).round())),
        ),
      );
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
          ..grid = grid
          ..peaks = over
          ..detail = detail
          ..busy = null;
      });
      // prepared stems load in a moment: have them ready on the pads
      final method = engine.aiModel != null ? 'ai' : 'fast';
      if (await engine.isPrepared(song, method) && mounted && decks[i] == d) {
        await toggleStems(i);
      }
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
    if (d.stemDetail == null && l.stems != null) {
      final stems = l.stems!,
          bins = math.max(1, (l.durationSec * _pps).round());
      final sd = await Isolate.run(
        () => {for (final s in stemNames) s: overview(stems[s]!, bins)},
      );
      if (!mounted || decks[i] != d) return;
      d.stemDetail = sd;
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

  /// Moves the playhead by [beats] (negative: back), keeping the phase.
  void beatJump(int i, int beats) {
    final p = _beatSec(i);
    if (p == 0) return;
    final dur = decks[i].loaded?.durationSec ?? 0;
    deck(i).seek((deck(i).time + beats * p).clamp(0, dur));
    setState(() {});
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

  void _stemPreset(int i, String which) {
    final d = decks[i];
    for (final s in stemNames) {
      d.gains[s] = switch (which) {
        'instrumental' => s == 'vocals' ? 0 : 1,
        'acapella' => s == 'vocals' ? 1 : 0,
        _ => 1,
      };
    }
    _applyGains(i);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(handoffProvider, (_, h) {
      if (h != null && h.page == 'dj') {
        unawaited(load(decks[0].song != null ? 1 : 0, h.song));
      }
    });
    final t = DjTokens.of(context);
    return LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth >= 960;
        final deckA = _deckPanel(0), deckB = _deckPanel(1);
        final mixerPanel = _mixer(wide);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            StudioPanel(
              child: Column(
                children: [
                  for (var i = 0; i < 2; i++)
                    Padding(
                      padding: EdgeInsets.only(top: i == 0 ? 0 : 6),
                      child: _scroller(i, t),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            if (wide)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: deckA),
                  const SizedBox(width: 10),
                  SizedBox(width: 200, child: mixerPanel),
                  const SizedBox(width: 10),
                  Expanded(child: deckB),
                ],
              )
            else ...[
              deckA,
              const SizedBox(height: 10),
              mixerPanel,
              const SizedBox(height: 10),
              deckB,
            ],
            const SizedBox(height: 10),
            _LibraryStrip(onLoad: load, decks: decks),
          ],
        );
      },
    );
  }

  /// One deck's scrolling waveform with its beatgrid.
  Widget _scroller(int i, DjTokens t) {
    final d = decks[i], l = d.loaded, dk = deck(i);
    final letter = i == 0 ? 'A' : 'B';
    return SizedBox(
      height: 84,
      child: Row(
        children: [
          SizedBox(
            width: 26,
            child: Text(
              letter,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: playingOf(i) ? t.accent : t.muted,
              ),
            ),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: GestureDetector(
                // drag to nudge through the track like a platter
                onHorizontalDragUpdate: l == null
                    ? null
                    : (e) {
                        final w = context.size?.width ?? 800;
                        final span = _window * dk.tempo;
                        dk.seek(
                          (dk.time - e.delta.dx / w * span).clamp(
                            0,
                            l.durationSec,
                          ),
                        );
                      },
                child: CustomPaint(
                  painter: _ScrollPainter(
                    time: dk.time,
                    span: _window * dk.tempo,
                    detail: d.detail,
                    stems: d.stems ? d.stemDetail : null,
                    gains: d.gains,
                    grid: d.grid,
                    bpm: l?.analysis?.bpm,
                    firstBeat: l?.analysis?.firstBeat,
                    cues: d.cues,
                    loop: dk.reader?.loop == null
                        ? null
                        : (
                            dk.reader!.loop!.$1 / dk.sampleRate,
                            dk.reader!.loop!.$2 / dk.sampleRate,
                          ),
                    colors: stemColors(t),
                    t: t,
                    empty: l == null
                        ? (d.busy ??
                              'Deck $letter: load a song from the library below')
                        : null,
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _deckPanel(int i) {
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
    final left = math.max(0.0, dur - dk.time);
    final big = TextStyle(
      fontSize: DjType.heading,
      fontWeight: FontWeight.w800,
      color: t.text,
    );
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: playing ? t.accent : t.line),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
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
                      Text(
                        d.song?.artist ??
                            (d.song == null
                                ? 'Load a song from the library below'
                                : ''),
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: t.faint,
                          fontSize: DjType.small,
                        ),
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(bpm > 0 ? bpm.toStringAsFixed(1) : '—', style: big),
                    Text(
                      a == null
                          ? 'BPM'
                          : '${_shiftedKey(a.key.tonic, a.key.mode, semis)}'
                                '${semis != 0 ? ' (${semis > 0 ? '+' : ''}$semis)' : ''} · ${a.key.camelot}',
                      style: TextStyle(color: t.muted, fontSize: DjType.small),
                    ),
                  ],
                ),
              ],
            ),
            if (d.busy != null && l != null)
              StudioProgress(
                d.busy!,
                d.busy!.startsWith('Separating') ? d.progress : null,
              ),
            if (d.busy != null && l == null) StudioProgress(d.busy!, null),
            if (l != null && d.peaks != null) ...[
              const SizedBox(height: 8),
              WaveView(
                peaks: d.peaks!,
                progress: dur == 0 ? 0 : (dk.time / dur).clamp(0, 1),
                height: 40,
                markers: [
                  for (var n = 0; n < d.cues.length; n++)
                    if (d.cues[n] != null && dur > 0)
                      (d.cues[n]! / dur, '${n + 1}'),
                ],
                onSeek: (f) => dk.seek(f * dur),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Text(fmtTime(dk.time)),
                  const Spacer(),
                  Text(
                    '−${fmtTime(left)}',
                    style: TextStyle(
                      color: left < 30 && dur > 60 ? t.warn : t.muted,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
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
                    tooltip:
                        'Match tempo and line up the beats with the other deck',
                  ),
                  chip(
                    'Key sync',
                    other.loaded != null &&
                        a != null &&
                        other.loaded!.analysis != null &&
                        _shiftedKey(a.key.tonic, a.key.mode, semis) ==
                            _shiftedKey(
                              other.loaded!.analysis!.key.tonic,
                              other.loaded!.analysis!.key.mode,
                              deck(1 - i).semis.round(),
                            ),
                    other.loaded == null ? null : () => matchKey(i),
                    tooltip:
                        'Shift this deck into a key that mixes with the other',
                  ),
                  if (d.grid != null)
                    Tooltip(
                      message: d.grid!.source == 'serato'
                          ? 'Beatgrid from Serato (read from the file)'
                          : d.grid!.stable
                          ? 'Steady beatgrid from analysis'
                          : 'Beatgrid with ${d.grid!.markers.length} tempo changes',
                      child: Icon(
                        Icons.grid_on,
                        size: 18,
                        color: d.grid!.source == 'serato' ? t.ok : t.muted,
                      ),
                    ),
                  if (l.prepared.isNotEmpty)
                    Tooltip(
                      message: 'Prepared stems',
                      child: Icon(Icons.layers, size: 18, color: t.ok),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: Knob(
                      label: 'Tempo',
                      value: dk.tempo,
                      min: 0.84,
                      max: 1.16,
                      width: double.infinity,
                      format: (v) => '${((v - 1) * 100).toStringAsFixed(1)}%',
                      onChanged: (v) => setState(() => dk.tempo = v),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Key down',
                    onPressed: () =>
                        setState(() => dk.semis = math.max(-6, dk.semis - 1)),
                    icon: const Icon(Icons.remove),
                  ),
                  TextButton(
                    onPressed: () => setState(() => dk.semis = 0),
                    child: const Text('Key 0'),
                  ),
                  IconButton(
                    tooltip: 'Key up',
                    onPressed: () =>
                        setState(() => dk.semis = math.min(6, dk.semis + 1)),
                    icon: const Icon(Icons.add),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              _padsHeader(i, t),
              const SizedBox(height: 6),
              _pads(i, t),
            ],
          ],
        ),
      ),
    );
  }

  Widget _padsHeader(int i, DjTokens t) {
    final d = decks[i];
    return SegmentedButton<String>(
      segments: const [
        ButtonSegment(value: 'cues', label: Text('Hot cues')),
        ButtonSegment(value: 'loops', label: Text('Loops')),
        ButtonSegment(value: 'stems', label: Text('Stems')),
      ],
      selected: {d.pads},
      showSelectedIcon: false,
      onSelectionChanged: (v) => setState(() => d.pads = v.first),
    );
  }

  /// Eight pads in two rows of four.
  Widget _padGrid(List<Widget> pads) => Column(
    children: [
      for (var r = 0; r < pads.length; r += 4)
        Padding(
          padding: EdgeInsets.only(top: r == 0 ? 0 : 6),
          child: Row(
            children: [
              for (var c = r; c < math.min(r + 4, pads.length); c++) ...[
                if (c > r) const SizedBox(width: 6),
                Expanded(child: pads[c]),
              ],
            ],
          ),
        ),
    ],
  );

  Widget _pad(
    String label, {
    required bool on,
    required Color color,
    VoidCallback? onTap,
    VoidCallback? onClear,
    String? tooltip,
    String? sub,
  }) {
    final t = DjTokens.of(context);
    final pad = Material(
      color: on ? color.withValues(alpha: 0.22) : t.panel2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: on ? color : t.line),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        onLongPress: onClear,
        onSecondaryTap: onClear,
        child: SizedBox(
          height: 44,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: onTap == null ? t.faint : (on ? t.text : t.muted),
                  ),
                ),
                if (sub != null)
                  Text(
                    sub,
                    style: TextStyle(color: t.faint, fontSize: DjType.caption),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    return tooltip == null ? pad : Tooltip(message: tooltip, child: pad);
  }

  Widget _pads(int i, DjTokens t) {
    final d = decks[i];
    switch (d.pads) {
      case 'loops':
        return _padGrid([
          for (final b in [1, 2, 4, 8])
            _pad(
              '$b',
              sub: b == 1 ? 'beat' : 'beats',
              on: d.loopBeats == b,
              color: t.accent,
              onTap: () => setLoop(i, b),
              tooltip: d.loopBeats == b
                  ? 'Exit the loop'
                  : 'Loop $b beats from here',
            ),
          for (final (label, beats) in [
            ('−4', -4),
            ('−1', -1),
            ('+1', 1),
            ('+4', 4),
          ])
            _pad(
              label,
              sub: 'jump',
              on: false,
              color: t.accent,
              onTap: () => beatJump(i, beats),
              tooltip:
                  'Jump ${beats.abs()} ${beats.abs() == 1 ? 'beat' : 'beats'} ${beats < 0 ? 'back' : 'ahead'}',
            ),
        ]);
      case 'stems':
        final colors = stemColors(t);
        if (!d.stems) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Split this song to drop the vocals, drums, bass or melodies live. Prepared stems load at once.',
                style: TextStyle(color: t.faint, fontSize: DjType.small),
              ),
              const SizedBox(height: 6),
              FilledButton.icon(
                onPressed: d.busy != null ? null : () => toggleStems(i),
                icon: const Icon(Icons.layers_outlined),
                label: const Text('Turn on stems'),
              ),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _padGrid([
              for (final s in stemNames)
                _pad(
                  _stemLabels[s]!,
                  on: d.gains[s]! > 0,
                  color: colors[s]!,
                  onTap: () {
                    d.gains[s] = d.gains[s]! > 0 ? 0 : 1;
                    _applyGains(i);
                    setState(() {});
                  },
                  tooltip: d.gains[s]! > 0
                      ? 'Mute ${_stemLabels[s]}'
                      : 'Bring back ${_stemLabels[s]}',
                ),
              _pad(
                'Instrumental',
                on:
                    d.gains['vocals'] == 0 &&
                    stemNames
                        .where((s) => s != 'vocals')
                        .every((s) => d.gains[s]! > 0),
                color: t.accent,
                onTap: () => _stemPreset(i, 'instrumental'),
              ),
              _pad(
                'Acapella',
                on:
                    d.gains['vocals']! > 0 &&
                    stemNames
                        .where((s) => s != 'vocals')
                        .every((s) => d.gains[s] == 0),
                color: t.accent,
                onTap: () => _stemPreset(i, 'acapella'),
              ),
              _pad(
                'All',
                on: stemNames.every((s) => d.gains[s] == 1),
                color: t.accent,
                onTap: () => _stemPreset(i, 'all'),
              ),
              _pad(
                'Stems off',
                on: false,
                color: t.accent,
                onTap: d.busy != null ? null : () => toggleStems(i),
                tooltip: 'Play the original mix',
              ),
            ]),
            const SizedBox(height: 6),
            for (final s in stemNames)
              Row(
                children: [
                  SizedBox(
                    width: 72,
                    child: Text(
                      _stemLabels[s]!,
                      style: TextStyle(
                        color: colors[s],
                        fontSize: DjType.small,
                      ),
                    ),
                  ),
                  Expanded(
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        activeTrackColor: colors[s],
                        thumbColor: colors[s],
                        trackHeight: 3,
                      ),
                      child: Slider(
                        value: d.gains[s]!,
                        onChanged: (v) {
                          d.gains[s] = v;
                          _applyGains(i);
                          setState(() {});
                        },
                      ),
                    ),
                  ),
                ],
              ),
          ],
        );
      default:
        return _padGrid([
          for (var n = 0; n < 8; n++)
            _pad(
              '${n + 1}',
              sub: d.cues[n] == null ? 'set' : fmtTime(d.cues[n]!),
              on: d.cues[n] != null,
              color: Color.lerp(t.accent, t.warn, n / 7)!,
              onTap: () => hotCue(i, n),
              onClear: () => hotCue(i, n, clear: true),
              tooltip: d.cues[n] != null
                  ? 'Jump to ${fmtTime(d.cues[n]!)} (right-click or hold to clear)'
                  : 'Set a cue at the playhead',
            ),
        ]);
    }
  }

  /// EQ, filter and volume for each deck, and the crossfader. Side by side
  /// (wide): a column of knobs per deck. Stacked (narrow): a row per deck.
  Widget _mixer(bool wide) {
    final t = DjTokens.of(context);
    String db(double v) => '${v > 0 ? '+' : ''}${v.toStringAsFixed(0)} dB';
    List<Widget> knobs(int i) {
      final dk = deck(i);
      return [
        for (final (band, label) in [
          ('high', 'High'),
          ('mid', 'Mid'),
          ('low', 'Low'),
        ])
          RotaryKnob(
            label: label,
            value: _eq(dk, band),
            min: -24,
            max: 6,
            reset: 0,
            bipolar: true,
            format: db,
            onChanged: (v) => setState(() => _setEq(dk, band, v)),
          ),
        RotaryKnob(
          label: 'Filter',
          value: dk.strip.filter,
          min: -1,
          max: 1,
          reset: 0,
          bipolar: true,
          format: (v) => v < -0.02
              ? 'low-pass'
              : v > 0.02
              ? 'high-pass'
              : 'off',
          onChanged: (v) => setState(() => dk.strip.filter = v),
        ),
        RotaryKnob(
          label: 'Volume',
          value: dk.volume,
          min: 0,
          max: 1.2,
          reset: 0.9,
          format: (v) => '${(v * 100).round()}%',
          onChanged: (v) => setState(() => dk.volume = v),
        ),
      ];
    }

    Widget letter(int i) => Text(
      i == 0 ? 'A' : 'B',
      style: TextStyle(fontWeight: FontWeight.w800, color: t.muted),
    );
    final channels = wide
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < 2; i++)
                Expanded(
                  child: Column(
                    children: [
                      letter(i),
                      for (final k in knobs(i))
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: k,
                        ),
                    ],
                  ),
                ),
            ],
          )
        : Column(
            children: [
              for (var i = 0; i < 2; i++)
                Padding(
                  padding: EdgeInsets.only(top: i == 0 ? 0 : 8),
                  child: Row(
                    children: [
                      SizedBox(width: 22, child: letter(i)),
                      for (final k in knobs(i)) Expanded(child: k),
                    ],
                  ),
                ),
            ],
          );
    return StudioPanel(
      title: 'Mixer',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          channels,
          const SizedBox(height: 8),
          Row(
            children: [
              const Text('A'),
              Expanded(
                child: Semantics(
                  label: 'Crossfader',
                  child: GestureDetector(
                    onDoubleTap: () => setState(() => mixer.crossfade = 0.5),
                    child: Slider(
                      value: mixer.crossfade,
                      onChanged: (v) => setState(() => mixer.crossfade = v),
                    ),
                  ),
                ),
              ),
              const Text('B'),
            ],
          ),
        ],
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

/// A scrolling waveform: [span] seconds of track around [time], the
/// playhead in the middle, beat lines (bar lines stronger), hot cues and
/// the loop. With stems on, each stem is drawn in its own colour at its
/// current level.
class _ScrollPainter extends CustomPainter {
  _ScrollPainter({
    required this.time,
    required this.span,
    required this.detail,
    required this.stems,
    required this.gains,
    required this.grid,
    required this.bpm,
    required this.firstBeat,
    required this.cues,
    required this.loop,
    required this.colors,
    required this.t,
    this.empty,
  });
  final double time, span;
  final Float32List? detail;
  final Map<String, Float32List>? stems;
  final Map<String, double> gains;
  final BeatGrid? grid;
  final double? bpm, firstBeat;
  final List<double?> cues;
  final (double, double)? loop;
  final Map<String, Color> colors;
  final DjTokens t;
  final String? empty;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height, mid = h / 2;
    canvas.drawRect(Offset.zero & size, Paint()..color = t.panel2);
    if (empty != null) {
      final tp = TextPainter(
        text: TextSpan(
          text: empty,
          style: TextStyle(
            fontFamily: DjType.family,
            color: t.faint,
            fontSize: DjType.small,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: w - 20);
      tp.paint(canvas, Offset(10, mid - tp.height / 2));
      return;
    }
    final start = time - span / 2;
    double x(double sec) => (sec - start) / span * w;

    // loop region
    final lp = loop;
    if (lp != null) {
      canvas.drawRect(
        Rect.fromLTRB(x(lp.$1), 0, x(lp.$2), h),
        Paint()..color = t.accent.withValues(alpha: 0.12),
      );
    }

    // beat lines: from the grid's markers when there is one
    final beat = Paint()..color = t.line;
    final bar = Paint()
      ..color = t.lineStrong
      ..strokeWidth = 1.5;
    void lines(
      double from,
      double to,
      double origin,
      double spb,
      int beatAtOrigin,
    ) {
      if (spb <= 0.05) return;
      final k0 = ((from - origin) / spb).ceil();
      for (var k = k0; origin + k * spb <= to; k++) {
        final s = origin + k * spb;
        final isBar = ((k + beatAtOrigin - 1) % 4 + 4) % 4 == 0;
        canvas.drawLine(Offset(x(s), 0), Offset(x(s), h), isBar ? bar : beat);
      }
    }

    final g = grid;
    if (g != null && g.markers.isNotEmpty) {
      for (var m = 0; m < g.markers.length; m++) {
        final mk = g.markers[m];
        final from = m == 0 ? 0.0 : mk.ms / 1000;
        final to = m + 1 < g.markers.length
            ? g.markers[m + 1].ms / 1000
            : double.infinity;
        final a = math.max(from, start), b = math.min(to, start + span);
        if (a < b) lines(a, b, mk.ms / 1000, 60 / mk.bpm, mk.beat);
      }
    } else if (bpm != null && bpm! > 0 && firstBeat != null) {
      lines(math.max(0, start), start + span, firstBeat!, 60 / bpm!, 1);
    }

    // waveform
    void wave(Float32List p, Color c, double scale) {
      final path = Path();
      final paint = Paint()..color = c;
      final i0 = math.max(0, (start * _pps).floor());
      final i1 = math.min(p.length, ((start + span) * _pps).ceil());
      if (i1 <= i0) return;
      final step = math.max(1, ((i1 - i0) / w).floor());
      path.moveTo(x(i0 / _pps), mid);
      for (var i = i0; i < i1; i += step) {
        path.lineTo(x(i / _pps), mid - p[i] * scale * (mid - 2));
      }
      for (var i = i1 - 1; i >= i0; i -= step) {
        path.lineTo(x(i / _pps), mid + p[i] * scale * (mid - 2));
      }
      path.close();
      canvas.drawPath(path, paint);
    }

    final st = stems;
    if (st != null) {
      for (final s in stemNames) {
        final p = st[s];
        if (p == null) continue;
        wave(p, colors[s]!.withValues(alpha: 0.55), gains[s]!.clamp(0.0, 1.0));
      }
    } else if (detail != null) {
      wave(detail!, t.accent.withValues(alpha: 0.75), 1);
    }

    // hot cues
    for (var n = 0; n < cues.length; n++) {
      final c = cues[n];
      if (c == null || c < start || c > start + span) continue;
      final cx = x(c);
      final col = Color.lerp(t.accent, t.warn, n / 7)!;
      canvas.drawLine(Offset(cx, 0), Offset(cx, h), Paint()..color = col);
      final tp = TextPainter(
        text: TextSpan(
          text: '${n + 1}',
          style: TextStyle(
            fontFamily: DjType.family,
            color: t.onAccent,
            fontSize: DjType.caption,
            fontWeight: FontWeight.w800,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      canvas.drawRect(
        Rect.fromLTWH(cx, 0, tp.width + 6, tp.height + 2),
        Paint()..color = col,
      );
      tp.paint(canvas, Offset(cx + 3, 1));
    }

    // playhead
    canvas.drawLine(
      Offset(w / 2, 0),
      Offset(w / 2, h),
      Paint()
        ..color = t.text
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_ScrollPainter o) => true;
}

/// The library under the decks: search, then load a song on A or B.
/// Songs with prepared stems are marked.
class _LibraryStrip extends ConsumerStatefulWidget {
  const _LibraryStrip({required this.onLoad, required this.decks});
  final Future<void> Function(int, SongRef) onLoad;
  final List<_DeckState> decks;
  @override
  ConsumerState<_LibraryStrip> createState() => _LibraryStripState();
}

class _LibraryStripState extends ConsumerState<_LibraryStrip> {
  String q = '';
  List<TrackRow> rows = const [];
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _load() {
    try {
      rows = ref
          .read(sessionProvider)
          .library
          .search(TrackQuery(text: q.trim().isEmpty ? null : q, limit: 60))
          .rows;
    } on Object {
      rows = const [];
    }
    if (mounted) setState(() {});
  }

  bool _prepared(StemsCache? cache, StudioEngine e, SongRef s) {
    if (cache == null) return false;
    for (final m in ['ai', 'fast']) {
      final src = StemsSource.of(
        s.path,
        m,
        m == 'fast'
            ? StudioEngine.fastModel
            : (e.aiModel == null
                  ? ''
                  : '${e.aiModel!.split(RegExp(r'[\\/]')).last}:${_size(e.aiModel!)}'),
      );
      if (src != null && File(cache.fileFor(src)).existsSync()) return true;
    }
    return false;
  }

  static int _size(String path) {
    try {
      return File(path).lengthSync();
    } on FileSystemException {
      return 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(versionProvider, (_, _) => _load());
    final t = DjTokens.of(context);
    final notation = '${ref.watch(settingsProvider)['key_notation']}';
    final e = applyStudioSettings(ref, ref.read(studioEngineProvider));
    final cache = e.stemsCache;
    final loadedIds = {for (final d in widget.decks) d.song?.id};
    return StudioPanel(
      title: 'Library',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search, size: 18),
              hintText: 'Search title, artist, genre…',
              isDense: true,
            ),
            onChanged: (v) {
              q = v;
              _debounce?.cancel();
              _debounce = Timer(const Duration(milliseconds: 200), _load);
            },
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 260,
            child: rows.isEmpty
                ? Center(
                    child: Text(
                      'No songs match.',
                      style: TextStyle(color: t.faint),
                    ),
                  )
                : ListView.builder(
                    itemCount: rows.length,
                    itemExtent: 40,
                    itemBuilder: (_, k) {
                      final r = rows[k], s = songOf(r);
                      final prepared = _prepared(cache, e, s);
                      return Row(
                        children: [
                          SizedBox(
                            width: 22,
                            child: prepared
                                ? Tooltip(
                                    message: 'Prepared stems',
                                    child: Icon(
                                      Icons.layers,
                                      size: 16,
                                      color: t.ok,
                                    ),
                                  )
                                : null,
                          ),
                          Expanded(
                            flex: 5,
                            child: Text(
                              s.title,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontWeight: loadedIds.contains(s.id)
                                    ? FontWeight.w800
                                    : FontWeight.w500,
                              ),
                            ),
                          ),
                          Expanded(
                            flex: 3,
                            child: Text(
                              s.artist ?? '',
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: t.muted),
                            ),
                          ),
                          SizedBox(
                            width: 56,
                            child: Text(
                              s.bpm == null ? '' : fmtBpm(s.bpm),
                              textAlign: TextAlign.right,
                            ),
                          ),
                          SizedBox(
                            width: 60,
                            child: Text(
                              fmtKey(s.key, notation),
                              textAlign: TextAlign.right,
                              style: TextStyle(color: t.muted),
                            ),
                          ),
                          const SizedBox(width: 8),
                          TextButton(
                            onPressed: () => widget.onLoad(0, s),
                            child: const Text('Load A'),
                          ),
                          TextButton(
                            onPressed: () => widget.onLoad(1, s),
                            child: const Text('Load B'),
                          ),
                        ],
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
