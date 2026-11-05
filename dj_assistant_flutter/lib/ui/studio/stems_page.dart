import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../studio/ai_stems.dart' show Cancelled;
import '../../studio/audio_out.dart';
import '../../studio/dsp.dart';
import '../../studio/engine.dart';
import '../../studio/stems.dart';
import '../state.dart';
import '../theme.dart';
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

  StudioEngine get engine => ref.read(studioEngineProvider);

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
      try {
        await engine.separate(
          l,
          onProgress: (f) {
            if (mounted) setState(() => progress = f);
          },
          method: how == 'ai' && engine.aiModel != null ? 'ai' : 'fast',
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
      final by = l.stemsBy == 'ai' ? ' with AI (processor)' : '';
      toast(
        'Split into 4 stems$by in ${secs.toStringAsFixed(1)} s.$note',
        error: note.isNotEmpty,
      );
    } on Cancelled {
      if (mounted) setState(() => phase = 'idle');
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          error = errText(e);
          phase = 'idle';
        });
      }
    }
  }

  void play([double? from]) {
    final l = loaded;
    if (l == null) return;
    player.play(from ?? pos, volumes);
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
            style: TextStyle(color: t.faint, fontSize: 12.5),
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
      main = StudioPanel(
        child: SizedBox(
          height: 200,
          child: Center(
            child: Text(
              'Choose a song to split it into stems.',
              style: TextStyle(color: t.faint),
            ),
          ),
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
                          fontSize: 17,
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
                method == 'ai' && engine.aiModel != null
                    ? 'Separating with AI on the processor… ${(progress * 100).round()}%'
                    : 'Separating stems on ${engine.workers} cores… ${(progress * 100).round()}%',
                progress,
              ),
              if (method == 'ai' && engine.aiModel != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton(
                    onPressed: engine.cancelAi,
                    child: const Text('Stop'),
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
                style: TextStyle(color: t.faint, fontSize: 12),
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
                SizedBox(width: 360, child: picker),
                const SizedBox(width: 12),
                Expanded(child: main),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [picker, const SizedBox(height: 12), main],
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
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        Text(
          label,
          style: TextStyle(color: DjTokens.of(context).faint, fontSize: 11),
        ),
      ],
    ),
  );
}
