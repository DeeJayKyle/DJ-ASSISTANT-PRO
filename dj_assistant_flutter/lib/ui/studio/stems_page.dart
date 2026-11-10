import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../studio/ai_stems.dart' show Cancelled;
import '../../studio/audio_out.dart';
import '../../studio/dsp.dart';
import '../../core/diag_log.dart';
import '../../core/library.dart' show TrackQuery;
import '../../studio/engine.dart';
import '../../studio/stems.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets.dart' show EmptyState;
import 'common.dart';

const stemLabels = {
  'mix': 'Full song',
  'vocals': 'Vocals',
  'drums': 'Drums',
  'bass': 'Bass',
  'melodies': 'Melodies',
  'instrumental': 'Instrumental',
};

/// Stems: split a song into vocals, drums, bass and melodies; key, tempo and
/// live chords; stems (WAV) and MIDI downloads. All on this computer.
class StemsPage extends ConsumerStatefulWidget {
  const StemsPage({super.key});
  @override
  ConsumerState<StemsPage> createState() => _StemsPageState();
}

class _StemsPageState extends ConsumerState<StemsPage> {
  SongRef? song;
  Loaded? loaded;
  String phase = 'idle'; // idle | loading | splitting | ready

  /// AI stems being made in the background while the Fast ones play
  /// (null: none on the way).
  double? aiBehind;

  /// The split in progress runs the AI model (not the Fast method).
  bool splittingAi = false;
  double progress = 0;
  String error = '';
  final gains = {for (final s in stemNames) s: 1.0};
  String? solo;
  double pos = 0;
  final dl = {'vocals', 'drums', 'bass', 'melodies', 'instrumental'};
  bool midiBusy = false;
  String method = 'fast';
  bool? aiReady;
  Map<String, Float32List>? peaks;
  final player = LayerPlayer();
  Timer? _tick;

  // Settings → Limits apply as soon as they change
  StudioEngine get engine =>
      applyStudioSettings(ref, ref.read(studioEngineProvider));

  @override
  void initState() {
    super.initState();
    _checkAi(first: true);
  }

  @override
  void dispose() {
    _tick?.cancel();
    unawaited(player.dispose());
    super.dispose();
  }

  void _checkAi({bool first = false}) {
    final m = aiStemsModel(ref);
    engine.aiModel = m;
    aiReady = m != null;
    if (m != null && first) method = 'ai';
    if (m == null) method = 'fast';
  }

  double eff(String st) => solo != null ? (solo == st ? 1 : 0) : gains[st]!;
  List<double> get volumes => [for (final s in stemNames) eff(s)];

  Future<void> pick(SongRef s, [String? how]) async {
    how ??= method;
    if (aiBehind != null) engine.cancelAi();
    aiBehind = null;
    player.stop();
    _tick?.cancel();
    setState(() {
      song = s;
      loaded = null;
      peaks = null;
      error = '';
      phase = 'loading';
      progress = 0;
      pos = 0;
    });
    try {
      final l = await engine.load(s);
      await engine.analyse(l);
      if (!mounted || song != s) return;
      setState(() => phase = 'splitting');
      final t0 = DateTime.now();
      var note = '';
      // AI: Fast stems first (seconds), AI stems swapped in when ready,
      // unless this song's AI stems are already made
      final ai = how == 'ai' && engine.aiModel != null;
      final readyAi = ai && await engine.isPrepared(s, 'ai');
      final behind = ai && l.aiStems == null && !readyAi;
      final wasPrepared =
          readyAi || (!ai && await engine.isPrepared(s, 'fast'));
      setState(() => splittingAi = ai && !behind);
      try {
        await engine.separate(
          l,
          onProgress: (f) {
            if (mounted) setState(() => progress = f);
          },
          method: ai && !behind ? 'ai' : 'fast',
        );
      } on StudioException catch (e) {
        if (!e.fallback) rethrow;
        note = ' ${e.message}';
      }
      if (!mounted || song != s) return;
      ref.read(splitSongsProvider.notifier).mark(s.id);
      final pk = {for (final st in stemNames) st: overview(l.stems![st]!, 500)};
      await player.load([
        for (final st in stemNames) l.stems![st]!,
      ], l.sampleRate);
      setState(() {
        loaded = l;
        peaks = pk;
        phase = 'ready';
      });
      final secs = DateTime.now().difference(t0).inMilliseconds / 1000;
      final by = l.stemsBy == 'ai'
          ? ' with AI (${engine.aiDevice == 'gpu' ? 'graphics card' : 'processor'})'
          : '';
      toast(
        wasPrepared && l.prepared.contains(l.stemsBy)
            ? 'Prepared stems loaded in ${secs.toStringAsFixed(1)} s.'
            : behind
            ? 'Fast stems ready in ${secs.toStringAsFixed(1)} s. AI stems are on the way; they replace these when done.'
            : 'Split into 4 stems$by in ${secs.toStringAsFixed(1)} s.$note',
        error: note.isNotEmpty,
      );
      if (behind) unawaited(_aiBehind(l, s));
    } on Cancelled {
      if (mounted) setState(() => phase = 'idle');
    } on Object catch (e, st) {
      DiagLog.error('stems', 'splitting ${s.path} failed: $e', st);
      if (mounted) {
        setState(() {
          error = errText(e);
          phase = 'idle';
        });
      }
    }
  }

  Future<void> play([double? from]) async {
    final l = loaded;
    if (l == null) return;
    if (!await player.play(from ?? pos, volumes)) {
      toast(
        'No sound output: the sound card could not be started (see Settings → About → Open log folder).',
        error: true,
      );
      return;
    }
    if (!mounted) return;
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (!mounted) return;
      if (player.ended) {
        _tick?.cancel();
        player.stop();
      }
      setState(() => pos = player.position.clamp(0, l.durationSec));
    });
    setState(() {});
  }

  /// Makes the AI stems while the Fast ones play, then swaps them in at the
  /// same position (playback keeps going).
  Future<void> _aiBehind(Loaded l, SongRef s) async {
    setState(() => aiBehind = 0);
    final t0 = DateTime.now();
    try {
      await engine.separate(
        l,
        method: 'ai',
        onProgress: (f) {
          if (mounted && song == s) setState(() => aiBehind = f);
        },
      );
    } on Cancelled {
      if (mounted && song == s) setState(() => aiBehind = null);
      return;
    } on StudioException catch (e) {
      // the AI couldn't run: the Fast stems stay
      if (mounted && song == s) {
        setState(() => aiBehind = null);
        toast(e.message, error: true);
      }
      return;
    } on Object catch (e, st) {
      DiagLog.error('stems', 'AI stems for ${s.path} failed: $e', st);
      if (mounted && song == s) {
        setState(() => aiBehind = null);
        toast(errText(e), error: true);
      }
      return;
    }
    if (!mounted || song != s || l.stemsBy != 'ai') return;
    final wasPlaying = player.playing, at = player.position;
    final pk = {for (final st in stemNames) st: overview(l.stems![st]!, 500)};
    await player.load([
      for (final st in stemNames) l.stems![st]!,
    ], l.sampleRate);
    if (!mounted) return;
    setState(() {
      peaks = pk;
      aiBehind = null;
      pos = at;
    });
    if (wasPlaying) await play(at);
    final secs = DateTime.now().difference(t0).inMilliseconds / 1000;
    toast(
      'AI stems ready (${engine.aiDevice == 'gpu' ? 'graphics card' : 'processor'}, ${secs.toStringAsFixed(0)} s). Now playing the AI stems.',
    );
  }

  void pause() {
    pos = player.position;
    player.stop();
    _tick?.cancel();
    setState(() {});
  }

  void _gainsChanged() {
    player.setVolumes(volumes);
    setState(() {});
  }

  Future<void> downloadStems() async {
    final l = loaded, s = song;
    if (l == null || s == null) return;
    final files = <(String, Uint8List)>[
      for (final st in stemNames)
        if (dl.contains(st))
          (
            '${safeName(s.title)} - ${stemLabels[st]}.wav',
            encodeWav(l.stems![st]!, l.sampleRate),
          ),
      if (dl.contains('instrumental'))
        (
          '${safeName(s.title)} - Instrumental.wav',
          encodeWav(instrumental(l.stems!), l.sampleRate),
        ),
    ];
    if (files.isEmpty) return;
    await guard(() async {
      final where = await saveStudioFiles(
        '${safeName(s.title)} - Stems',
        files,
      );
      if (where != null) {
        toast('Saved ${files.length} stem${files.length == 1 ? '' : 's'}.');
      }
    });
  }

  Future<void> downloadMidi() async {
    final l = loaded, s = song;
    if (l == null || s == null) return;
    setState(() => midiBusy = true);
    await guard(() async {
      final (bytes, counts) = await engine.midi(l);
      final where = await saveStudioFile('${safeName(s.title)}.mid', bytes);
      if (where != null) {
        toast(
          'MIDI saved: ${counts.map((c) => '${c.$1} ${c.$2}').join(', ')} notes.',
        );
      }
    });
    if (mounted) setState(() => midiBusy = false);
  }

  @override
  Widget build(BuildContext context) {
    // a song sent here (by the assistant or another page) is split at once
    ref.listen(handoffProvider, (_, h) {
      if (h != null && h.page == 'stems') unawaited(pick(h.song, h.method));
    });
    final t = DjTokens.of(context);
    final l = loaded, a = l?.analysis;
    final chord = a == null ? null : chordAt(a.chords, pos);
    final next = a?.chords.where((c) => c.start > pos).firstOrNull;
    final dur = l?.durationSec ?? 0;
    final playing = player.playing;
    final picker = StudioPanel(
      title: 'Pick a song',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Split it into vocals, drums, bass and melodies, find its key, tempo and chords, and turn the parts into MIDI. It all runs on this computer.',
            style: TextStyle(color: t.faint, fontSize: DjType.small),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('Separation', style: TextStyle(color: t.muted)),
              chip(
                'AI (best)',
                method == 'ai',
                aiReady == true ? () => setState(() => method = 'ai') : null,
                tooltip: aiReady == true
                    ? 'HTDemucs AI model: the cleanest stems'
                    : 'Install Pro Stems AI first',
              ),
              chip(
                'Fast',
                method == 'fast',
                () => setState(() => method = 'fast'),
              ),
              if (aiReady == false)
                TextButton(
                  onPressed: () =>
                      ref.read(viewProvider.notifier).go('settings'),
                  child: const Text('Get Pro Stems AI'),
                ),
              if (song != null &&
                  l != null &&
                  l.stemsBy != method &&
                  phase == 'ready')
                TextButton(
                  onPressed: () => pick(song!, method),
                  child: Text(
                    'Split again with ${method == 'ai' ? 'AI' : 'Fast'}',
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          SongPicker(onPick: pick, label: 'Song to split'),
        ],
      ),
    );
    final Widget main;
    if (song == null) {
      main = const StudioPanel(
        child: EmptyState(
          icon: Icons.layers_outlined,
          title: 'Choose a song to split it into stems',
          message: 'Pick one from the list. You get vocals, drums, bass and melodies to play, mute and download, plus its key, tempo and chords.',
        ),
      );
    } else {
      main = StudioPanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        song!.title,
                        style: const TextStyle(
                          fontSize: DjType.heading,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (song!.artist != null)
                        Text(song!.artist!, style: TextStyle(color: t.faint)),
                    ],
                  ),
                ),
                if (a != null) ...[
                  _Stat('${(a.bpm * 10).round() / 10}', 'BPM'),
                  _Stat(a.key.short, a.key.camelot),
                  Semantics(
                    liveRegion: true,
                    child: _Stat(
                      chord?.name ?? '—',
                      next != null ? 'next ${next.name}' : 'chord',
                    ),
                  ),
                ],
              ],
            ),
            if (error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(error, style: TextStyle(color: t.danger)),
              ),
            if (phase == 'loading')
              const StudioProgress('Reading the song…', null),
            if (phase == 'splitting') ...[
              StudioProgress(
                splittingAi
                    ? 'Separating with AI… ${(progress * 100).round()}%'
                    : 'Separating stems on ${engine.workers} cores… ${(progress * 100).round()}%',
                progress,
              ),
              if (splittingAi)
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton(
                    onPressed: engine.cancelAi,
                    child: const Text('Stop'),
                  ),
                ),
            ],
            if (phase == 'ready' && aiBehind != null) ...[
              StudioProgress(
                'Fast stems ready. Making the AI stems in the background… ${(aiBehind! * 100).round()}%',
                aiBehind,
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton(
                  onPressed: engine.cancelAi,
                  child: const Text('Keep the Fast stems'),
                ),
              ),
            ],
            if (phase == 'ready' && l != null && peaks != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  FilledButton.icon(
                    onPressed: playing ? pause : play,
                    icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                    label: Text(playing ? 'Pause' : 'Play'),
                  ),
                  const SizedBox(width: 10),
                  Text('${fmtTime(pos)} / ${fmtTime(dur)}'),
                  const Spacer(),
                  OutlinedButton(
                    onPressed: () =>
                        ref.read(handoffProvider.notifier).send('remix', song!),
                    child: const Text('Remix it →'),
                  ),
                  const SizedBox(width: 6),
                  OutlinedButton(
                    onPressed: () =>
                        ref.read(handoffProvider.notifier).send('dj', song!),
                    child: const Text('DJ it →'),
                  ),
                ],
              ),
              for (final st in stemNames)
                Opacity(
                  opacity: eff(st) == 0 ? 0.45 : 1,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            SizedBox(
                              width: 90,
                              child: Text(
                                stemLabels[st]!,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            chip('Solo', solo == st, () {
                              solo = solo == st ? null : st;
                              _gainsChanged();
                            }),
                            const SizedBox(width: 4),
                            chip('Mute', gains[st] == 0, () {
                              gains[st] = gains[st] == 0 ? 1 : 0;
                              _gainsChanged();
                            }),
                            Expanded(
                              child: Semantics(
                                label: '${stemLabels[st]} volume',
                                child: Slider(
                                  value: gains[st]!,
                                  max: 1.5,
                                  onChanged: (v) {
                                    gains[st] = v;
                                    _gainsChanged();
                                  },
                                ),
                              ),
                            ),
                          ],
                        ),
                        WaveView(
                          peaks: peaks![st]!,
                          progress: dur == 0 ? 0 : pos / dur,
                          height: 40,
                          onSeek: (f) {
                            pos = f * dur;
                            if (playing) {
                              play(pos);
                            } else {
                              setState(() {});
                            }
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  for (final k in [
                    'vocals',
                    'drums',
                    'bass',
                    'melodies',
                    'instrumental',
                  ])
                    chip(stemLabels[k]!, dl.contains(k), () {
                      setState(() => dl.contains(k) ? dl.remove(k) : dl.add(k));
                    }),
                  FilledButton(
                    onPressed: dl.isEmpty ? null : downloadStems,
                    child: const Text('Download stems (WAV)'),
                  ),
                  OutlinedButton(
                    onPressed: midiBusy ? null : downloadMidi,
                    child: Text(midiBusy ? 'Making MIDI…' : 'Download MIDI'),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '${l.stemsBy == 'ai' ? 'Separated with the HTDemucs AI model on this computer.' : 'Separated with fast signal processing: private and quick, but parts can bleed into each other more than with the AI model.'} MIDI has a track each for bass, melody, vocal melody, chords and drums.',
                style: TextStyle(color: t.faint, fontSize: DjType.small),
              ),
            ],
          ],
        ),
      );
    }
    return LayoutBuilder(
      builder: (_, c) => c.maxWidth > 980
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 360,
                  child: Column(
                    children: [
                      picker,
                      const SizedBox(height: 12),
                      PrepareStemsPanel(method: method),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(child: main),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                picker,
                const SizedBox(height: 12),
                main,
                const SizedBox(height: 12),
                PrepareStemsPanel(method: method),
              ],
            ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.value, this.label);
  final String value, label;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 18),
    child: Column(
      children: [
        Text(
          value,
          style: const TextStyle(
            fontSize: DjType.heading,
            fontWeight: FontWeight.w700,
          ),
        ),
        Text(
          label,
          style: TextStyle(
            color: DjTokens.of(context).faint,
            fontSize: DjType.caption,
          ),
        ),
      ],
    ),
  );
}

/// Prepare stems for a whole crate before a gig: each song is split once
/// and kept on this computer, so it loads instantly in Stems or on a deck.
class PrepareStemsPanel extends ConsumerStatefulWidget {
  const PrepareStemsPanel({super.key, required this.method});
  final String method;
  @override
  ConsumerState<PrepareStemsPanel> createState() => _PrepareStemsPanelState();
}

class _PrepareStemsPanelState extends ConsumerState<PrepareStemsPanel> {
  int? crateId;
  bool running = false, stop = false;
  int done = 0, total = 0, failed = 0;
  double part = 0;
  String? current;

  Future<void> run() async {
    final s = ref.read(sessionProvider);
    final id = crateId;
    if (id == null) return;
    final engine = applyStudioSettings(ref, ref.read(studioEngineProvider));
    if (engine.stemsCache == null) {
      toast('Turn on prepared stems in Settings → Studio first.', error: true);
      return;
    }
    final songs = [
      for (final r in s.crates.tracks(id, limit: TrackQuery.all).rows)
        songOf(r),
    ];
    setState(() {
      running = true;
      stop = false;
      done = 0;
      failed = 0;
      total = songs.length;
      part = 0;
    });
    try {
      final n = await engine.prepare(
        songs,
        method: widget.method,
        cancelled: () => stop,
        onProgress: (f) {
          if (mounted) setState(() => part = f);
        },
        onSong: (i, song, err) {
          if (!mounted) return;
          setState(() {
            done = i + 1;
            part = 0;
            current = song.title;
            if (err != null) failed++;
          });
          if (err != null) {
            DiagLog.error('stems', 'preparing ${song.path} failed: $err');
          } else {
            ref.read(splitSongsProvider.notifier).mark(song.id);
          }
        },
      );
      toast(
        stop
            ? 'Stopped: $n of $total songs have prepared stems.'
            : failed == 0
            ? 'Prepared stems for all $n songs.'
            : 'Prepared stems for $n songs; $failed could not be split (see the log).',
        error: failed > 0,
      );
    } on Object catch (e) {
      toast(errText(e), error: true);
    } finally {
      if (mounted) setState(() => running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = DjTokens.of(context);
    final s = ref.watch(sessionProvider);
    final crates = s.crates.list();
    return StudioPanel(
      title: 'Prepare stems',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Split a whole crate once, ahead of a gig. The stems are kept on this computer (not beside your music) and load instantly here and on the decks.',
            style: TextStyle(color: t.faint, fontSize: DjType.small),
          ),
          const SizedBox(height: 8),
          DropdownButton<int>(
            isExpanded: true,
            hint: const Text('Choose a crate'),
            value: crates.any((c) => c.id == crateId) ? crateId : null,
            items: [
              for (final c in crates)
                DropdownMenuItem(
                  value: c.id,
                  child: Text(
                    '${c.name} (${c.trackCount})',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: running ? null : (v) => setState(() => crateId = v),
          ),
          const SizedBox(height: 8),
          if (running) ...[
            StudioProgress(
              'Song ${math.min(done + 1, total)} of $total'
              '${current == null ? '' : ' (last: $current)'}… ${(part * 100).round()}%',
              total == 0 ? null : (done + part) / total,
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton(
                onPressed: stop ? null : () => setState(() => stop = true),
                child: const Text('Stop after this song'),
              ),
            ),
          ] else
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                onPressed: crateId == null ? null : run,
                icon: const Icon(Icons.layers_outlined),
                label: Text(
                  'Prepare with ${widget.method == 'ai' ? 'AI' : 'Fast'}',
                ),
              ),
            ),
        ],
      ),
    );
  }
}
