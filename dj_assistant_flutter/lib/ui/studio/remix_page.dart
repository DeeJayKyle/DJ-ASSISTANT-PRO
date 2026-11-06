import 'package:flutter/foundation.dart' show defaultTargetPlatform;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/diag_log.dart';
import '../../studio/audio_out.dart';
import '../../studio/dsp.dart' show encodeWav;
import '../../studio/engine.dart';
import '../../studio/remix.dart';
import '../../studio/stems.dart' show noteNames;
import '../state.dart';
import '../theme.dart';
import 'common.dart';

const _layers = [
  ('mix', 'Song'),
  ('vocals', 'Vocals'),
  ('drums', 'Drums'),
  ('bass', 'Bass'),
  ('melodies', 'Melodies'),
];
const layerColors = {
  'mix': Color(0xFF7AA2FF),
  'vocals': Color(0xFFFF7AA8),
  'drums': Color(0xFFFFB547),
  'bass': Color(0xFFB38CFF),
  'melodies': Color(0xFF3EE6C4),
};
const _head = 220.0;
const _outRate = 44100;

/// Remix: clips from songs and stems on a beat grid; one tempo and key; every
/// clip auto-synced.
class RemixPage extends ConsumerStatefulWidget {
  const RemixPage({super.key, this.active = true});
  final bool active;
  @override
  ConsumerState<RemixPage> createState() => _RemixPageState();
}

class _RemixPageState extends ConsumerState<RemixPage> {
  Project project = const Project();
  SongRef? selected;
  (String, double)? busy;
  double zoom = 14;
  double head = 0; // beats
  String? sel;
  final past = <Project>[], future = <Project>[];
  final player = LayerPlayer();
  Timer? _tick;
  late final TextEditingController _name = TextEditingController(
    text: project.name,
  );

  StudioEngine get engine => ref.read(studioEngineProvider);

  @override
  void dispose() {
    _tick?.cancel();
    unawaited(player.dispose());
    _name.dispose();
    super.dispose();
  }

  void remember() {
    past.add(project);
    if (past.length > 60) past.removeAt(0);
    future.clear();
  }

  /// Any edit stops playback so what you hear matches the arrangement.
  void edit(Project Function(Project) fn) {
    if (player.playing) stop();
    setState(() => project = fn(project));
  }

  void change(Project Function(Project) fn) {
    remember();
    edit(fn);
  }

  void undo() {
    if (past.isEmpty) return;
    future.add(project);
    final prev = past.removeLast();
    edit((_) => prev);
  }

  void redo() {
    if (future.isEmpty) return;
    past.add(project);
    final next = future.removeLast();
    edit((_) => next);
  }

  Future<void> addLayer(SongRef song, String layer) async {
    try {
      setState(
        () => busy = (
          layer == 'mix' ? 'Reading the song…' : 'Separating stems…',
          0,
        ),
      );
      final l = await engine.load(song);
      if (layer != 'mix') {
        await engine.separate(
          l,
          method: l.stemsBy,
          onProgress: (p) {
            if (mounted) setState(() => busy = ('Separating stems…', p));
          },
        );
        ref.read(splitSongsProvider.notifier).mark(song.id);
      }
      var src = engine.remixSources[song.id];
      if (src == null || (layer != 'mix' && src.layers[layer] == null)) {
        setState(() => busy = ('Getting it ready to sync…', 0.9));
        src = await engine.remixSource(l, withStems: l.stems != null);
      }
      final s = src;
      remember();
      setState(() {
        final first = project.tracks.isEmpty;
        final base = first
            ? project.copyWith(
                bpm: (s.bpm * 10).round() / 10,
                tonic: s.tonic,
                mode: s.mode,
              )
            : project;
        project = base.copyWith(
          tracks: [...base.tracks, newTrackFor(s, layer)],
        );
      });
    } on Object catch (e, st) {
      DiagLog.error('remix', e, st);
      toast(errText(e), error: true);
    } finally {
      if (mounted) setState(() => busy = null);
    }
  }

  void stop() {
    _tick?.cancel();
    player.stop();
    setState(() {});
  }

  Future<Rendered> render({bool withTracks = false}) async {
    setState(() => busy = ('Rendering the remix…', 0.5));
    try {
      return await engine.render(project, _outRate, withTracks: withTracks);
    } finally {
      if (mounted) setState(() => busy = null);
    }
  }

  Future<void> play() async {
    if (player.playing) {
      stop();
      return;
    }
    if (project.tracks.isEmpty) return;
    try {
      final r = await render();
      await player.load([r.mix], _outRate);
      final from = head * 60 / project.bpm;
      player.play(math.min(from, player.duration - 0.01), [1]);
      final bpm = project.bpm;
      _tick?.cancel();
      _tick = Timer.periodic(const Duration(milliseconds: 40), (_) {
        if (!mounted) return;
        if (player.ended) {
          stop();
          return;
        }
        setState(() => head = player.position * bpm / 60);
      });
      setState(() {});
    } on Object catch (e, st) {
      DiagLog.error('remix', e, st);
      toast(errText(e), error: true);
    }
  }

  void removeClip(String id) => change(
    (p) => p.copyWith(
      tracks: [
        for (final t in p.tracks)
          if (t.clips.any((c) => c.id != id))
            t.copyWith(
              clips: [
                for (final c in t.clips)
                  if (c.id != id) c,
              ],
            ),
      ],
    ),
  );

  void duplicateClip(String id) => change(
    (p) => p.copyWith(
      tracks: [
        for (final t in p.tracks)
          () {
            final c = t.clips.where((x) => x.id == id).firstOrNull;
            if (c == null) return t;
            final end = t.clips.map((x) => x.end).reduce(math.max);
            return t.copyWith(
              clips: [
                ...t.clips,
                c.copyWith(id: uid('c'), start: end),
              ],
            );
          }(),
      ],
    ),
  );

  void updTrack(String id, RTrack Function(RTrack) fn) => change(
    (p) =>
        p.copyWith(tracks: [for (final t in p.tracks) t.id == id ? fn(t) : t]),
  );

  Future<void> exportMix() async {
    await guard(() async {
      final r = await render();
      final where = await saveStudioFile(
        '${safeName(project.name)}.wav',
        encodeWav(r.mix, _outRate),
      );
      if (where != null) toast('Remix exported.');
    });
  }

  Future<void> exportTracks() async {
    await guard(() async {
      final r = await render(withTracks: true);
      final files = <(String, Uint8List)>[
        ('${safeName(project.name)} - Mix.wav', encodeWav(r.mix, _outRate)),
        for (var i = 0; i < project.tracks.length; i++)
          if (r.tracks[project.tracks[i].id] != null)
            (
              '${'${i + 1}'.padLeft(2, '0')} ${safeName(project.tracks[i].name)}.wav',
              encodeWav(r.tracks[project.tracks[i].id]!, _outRate),
            ),
      ];
      final where = await saveStudioFiles(
        '${safeName(project.name)} - Tracks',
        files,
      );
      if (where != null) {
        toast('Exported the mix and ${files.length - 1} tracks.');
      }
    });
  }

  // drag: move | left | right | loop
  Clip? _dragStart;
  double _dragDx = 0;
  void _dragBegin(Clip c) {
    remember();
    _dragStart = c;
    _dragDx = 0;
    setState(() => sel = c.id);
  }

  void _dragUpdate(String trackId, String mode, double dx) {
    final s = _dragStart;
    if (s == null) return;
    _dragDx += dx;
    final d = (_dragDx / zoom).round();
    edit(
      (p) => p.copyWith(
        tracks: [
          for (final t in p.tracks)
            t.id != trackId
                ? t
                : t.copyWith(
                    clips: [
                      for (final c in t.clips)
                        c.id != s.id
                            ? c
                            : switch (mode) {
                                'move' => c.copyWith(
                                  start: math.max(0, s.start + d),
                                ),
                                'right' => c.copyWith(
                                  length: math.max(1, s.length + d),
                                ),
                                'left' => () {
                                  final dd = d.clamp(-s.offset, s.length - 1);
                                  return c.copyWith(
                                    start: math.max(0, s.start + dd),
                                    offset: s.offset + dd,
                                    length: s.length - dd,
                                  );
                                }(),
                                _ => c.copyWith(
                                  loops: math.max(
                                    1,
                                    ((s.length * s.loops + d) / s.length)
                                        .round(),
                                  ),
                                ),
                              },
                    ],
                  ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(handoffProvider, (_, h) {
      if (h != null && h.page == 'remix') setState(() => selected = h.song);
    });
    final t = DjTokens.of(context);
    final beats = projectBeats(project) + 8;
    final width = beats * zoom;
    final playing = player.playing;
    final library = StudioPanel(
      title: 'Library',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SongPicker(
            onPick: (s) => setState(() => selected = s),
            label: 'Song to add',
            height: 280,
          ),
          if (selected != null) ...[
            const SizedBox(height: 8),
            Text(
              selected!.title,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            Text(
              'Add the whole song or one of its stems:',
              style: TextStyle(color: t.faint, fontSize: 12),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final (id, label) in _layers)
                  ActionChip(
                    avatar: CircleAvatar(backgroundColor: layerColors[id]),
                    label: Text('+ $label'),
                    onPressed: busy != null
                        ? null
                        : () => addLayer(selected!, id),
                  ),
              ],
            ),
          ],
          if (busy != null) StudioProgress(busy!.$1, busy!.$2),
        ],
      ),
    );
    final toolbar = Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SizedBox(
          width: 200,
          child: TextField(
            controller: _name,
            decoration: const InputDecoration(
              labelText: 'Remix name',
              isDense: true,
            ),
            onChanged: (v) => project = project.copyWith(
              name: v.trim().isEmpty ? 'My Remix' : v,
            ),
          ),
        ),
        FilledButton.icon(
          onPressed: project.tracks.isEmpty || (busy != null && !playing)
              ? null
              : play,
          icon: Icon(playing ? Icons.stop : Icons.play_arrow),
          label: Text(playing ? 'Stop' : 'Play'),
        ),
        SizedBox(
          width: 110,
          child: TextFormField(
            key: ValueKey('bpm${project.bpm}'),
            initialValue: '${project.bpm}',
            decoration: const InputDecoration(
              labelText: 'Tempo',
              isDense: true,
            ),
            onFieldSubmitted: (v) => edit(
              (p) => p.copyWith(
                bpm: (double.tryParse(v) ?? 120).clamp(60, 200).toDouble(),
              ),
            ),
          ),
        ),
        DropdownButton<String>(
          value: '${project.tonic}:${project.mode}',
          items: [
            for (var i = 0; i < 12; i++)
              for (final m in ['major', 'minor'])
                DropdownMenuItem(
                  value: '$i:$m',
                  child: Text('${noteNames[i]} $m'),
                ),
          ],
          onChanged: (v) {
            if (v == null) return;
            final [tn, m] = v.split(':');
            edit((p) => p.copyWith(tonic: int.parse(tn), mode: m));
          },
        ),
        SizedBox(
          width: 140,
          child: Slider(
            value: zoom,
            min: 6,
            max: 40,
            label: 'Zoom',
            onChanged: (v) => setState(() => zoom = v),
          ),
        ),
        IconButton(
          tooltip: 'Undo (Ctrl+Z)',
          onPressed: past.isEmpty ? null : undo,
          icon: const Icon(Icons.undo),
        ),
        IconButton(
          tooltip: 'Redo (Ctrl+Shift+Z)',
          onPressed: future.isEmpty ? null : redo,
          icon: const Icon(Icons.redo),
        ),
        if (sel != null) ...[
          OutlinedButton(
            onPressed: () => duplicateClip(sel!),
            child: const Text('Duplicate clip'),
          ),
          OutlinedButton(
            onPressed: () {
              removeClip(sel!);
              setState(() => sel = null);
            },
            child: const Text('Delete clip'),
          ),
        ],
        OutlinedButton(
          onPressed: project.tracks.isEmpty || busy != null
              ? null
              : exportTracks,
          child: const Text('Export tracks'),
        ),
        FilledButton(
          onPressed: project.tracks.isEmpty || busy != null ? null : exportMix,
          child: const Text('Export remix (WAV)'),
        ),
      ],
    );
    final timeline = project.tracks.isEmpty
        ? SizedBox(
            height: 160,
            child: Center(
              child: Text(
                "Add a song or a stem from the library. Every clip follows the remix's tempo and key automatically.",
                style: TextStyle(color: t.faint),
                textAlign: TextAlign.center,
              ),
            ),
          )
        : Scrollbar(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: width + _head,
                child: Stack(
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        GestureDetector(
                          onTapDown: (d) {
                            final x = d.localPosition.dx - _head;
                            if (x >= 0) {
                              if (playing) stop();
                              setState(() => head = (x / zoom).roundToDouble());
                            }
                          },
                          child: SizedBox(
                            height: 22,
                            child: Stack(
                              children: [
                                for (var b = 0; b < (beats / 4).ceil(); b++)
                                  Positioned(
                                    left: _head + b * 4 * zoom,
                                    top: 2,
                                    child: Text(
                                      '${b + 1}',
                                      style: TextStyle(
                                        fontSize: 10,
                                        color: t.faint,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                        for (final tr in project.tracks) _track(tr, width, t),
                      ],
                    ),
                    Positioned(
                      left: _head + head * zoom,
                      top: 0,
                      bottom: 0,
                      child: IgnorePointer(
                        child: Container(
                          width: 1.5,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
    final arrangement = StudioPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          toolbar,
          const SizedBox(height: 10),
          timeline,
          const SizedBox(height: 6),
          Text(
            'Each clip is time-stretched to ${project.bpm} BPM and moved into ${noteNames[project.tonic]} ${project.mode} (the shortest way round, via the relative key for major/minor). Drag a clip to move it, its edges to trim, its top-right corner to loop.',
            style: TextStyle(color: t.faint, fontSize: 12),
          ),
        ],
      ),
    );
    final mod = defaultTargetPlatform == TargetPlatform.macOS;
    return CallbackShortcuts(
      bindings: widget.active
          ? {
              SingleActivator(
                LogicalKeyboardKey.keyZ,
                control: !mod,
                meta: mod,
              ): undo,
              SingleActivator(
                LogicalKeyboardKey.keyZ,
                control: !mod,
                meta: mod,
                shift: true,
              ): redo,
              SingleActivator(
                LogicalKeyboardKey.keyY,
                control: !mod,
                meta: mod,
              ): redo,
              SingleActivator(
                LogicalKeyboardKey.keyD,
                control: !mod,
                meta: mod,
              ): () {
                if (sel != null) duplicateClip(sel!);
              },
              const SingleActivator(LogicalKeyboardKey.delete): () {
                if (sel != null) {
                  removeClip(sel!);
                  setState(() => sel = null);
                }
              },
            }
          : const {},
      child: Focus(
        child: LayoutBuilder(
          builder: (_, c) => c.maxWidth > 1100
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: 300, child: library),
                    const SizedBox(width: 12),
                    Expanded(child: arrangement),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [library, const SizedBox(height: 12), arrangement],
                ),
        ),
      ),
    );
  }

  Widget _track(RTrack tr, double width, DjTokens t) {
    final last = tr.clips.isEmpty ? null : tr.clips.last;
    final endX = tr.clips.isEmpty
        ? 0.0
        : tr.clips.map((c) => c.end * zoom).reduce(math.max);
    return SizedBox(
      height: 64,
      child: Row(
        children: [
          SizedBox(
            width: _head,
            child: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Tooltip(
                          message: tr.name,
                          child: Text(
                            tr.name,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Remove ${tr.name}',
                        visualDensity: VisualDensity.compact,
                        iconSize: 16,
                        onPressed: () => change(
                          (p) => p.copyWith(
                            tracks: [
                              for (final x in p.tracks)
                                if (x.id != tr.id) x,
                            ],
                          ),
                        ),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      _mini(
                        'M',
                        tr.mute,
                        () => updTrack(tr.id, (x) => x.copyWith(mute: !x.mute)),
                      ),
                      _mini(
                        'S',
                        tr.solo,
                        () => updTrack(tr.id, (x) => x.copyWith(solo: !x.solo)),
                      ),
                      Expanded(
                        child: Slider(
                          value: tr.gain,
                          max: 1.5,
                          onChanged: (v) => edit(
                            (p) => p.copyWith(
                              tracks: [
                                for (final x in p.tracks)
                                  x.id == tr.id ? x.copyWith(gain: v) : x,
                              ],
                            ),
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 56,
                        child: Slider(
                          value: tr.pan,
                          min: -1,
                          onChanged: (v) => edit(
                            (p) => p.copyWith(
                              tracks: [
                                for (final x in p.tracks)
                                  x.id == tr.id ? x.copyWith(pan: v) : x,
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          SizedBox(
            width: width,
            child: Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(painter: _Grid(zoom, t.line)),
                ),
                for (final c in tr.clips) _clip(tr, c),
                if (last != null)
                  Positioned(
                    left: endX + 6,
                    top: 18,
                    child: IconButton.outlined(
                      tooltip: 'Repeat the last clip of ${tr.name}',
                      visualDensity: VisualDensity.compact,
                      iconSize: 16,
                      onPressed: () => updTrack(
                        tr.id,
                        (x) => x.copyWith(
                          clips: [
                            ...x.clips,
                            last.copyWith(
                              id: uid('c'),
                              start: last.end,
                              loops: 1,
                            ),
                          ],
                        ),
                      ),
                      icon: const Icon(Icons.add),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _mini(String label, bool on, VoidCallback f) => Padding(
    padding: const EdgeInsets.only(right: 4),
    child: InkWell(
      onTap: f,
      child: Container(
        width: 22,
        height: 22,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: on ? DjTokens.of(context).accent : null,
          border: Border.all(color: DjTokens.of(context).line),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          label,
          style: TextStyle(fontSize: 11, color: on ? Colors.black : null),
        ),
      ),
    ),
  );

  Widget _clip(RTrack tr, Clip c) {
    final w = c.length * c.loops * zoom;
    Widget handle(
      String mode, {
      double? left,
      double? right,
      double? top,
      double? height,
      double width = 8,
    }) => Positioned(
      left: left,
      right: right,
      top: top ?? 0,
      height: height,
      bottom: height == null ? 0 : null,
      width: width,
      child: MouseRegion(
        cursor: mode == 'loop'
            ? SystemMouseCursors.click
            : SystemMouseCursors.resizeLeftRight,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (_) => _dragBegin(c),
          onHorizontalDragUpdate: (d) => _dragUpdate(tr.id, mode, d.delta.dx),
          child: Container(
            color: mode == 'loop' ? Colors.white24 : Colors.transparent,
          ),
        ),
      ),
    );
    return Positioned(
      left: c.start * zoom,
      top: 8,
      width: math.max(4, w),
      height: 48,
      child: Semantics(
        label: 'Clip ${tr.name}',
        child: GestureDetector(
          onTap: () => setState(() => sel = c.id),
          onHorizontalDragStart: (_) => _dragBegin(c),
          onHorizontalDragUpdate: (d) => _dragUpdate(tr.id, 'move', d.delta.dx),
          child: Tooltip(
            message:
                '${c.length} beats${c.loops > 1 ? ' × ${c.loops}' : ''} — drag to move, edges to trim, top-right to loop',
            child: Container(
              decoration: BoxDecoration(
                color: layerColors[c.layer]!.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(5),
                border: sel == c.id
                    ? Border.all(color: Colors.white, width: 2)
                    : null,
              ),
              child: Stack(
                children: [
                  for (var i = 1; i < c.loops; i++)
                    Positioned(
                      left: i * c.length * zoom,
                      top: 0,
                      bottom: 0,
                      child: Container(width: 1, color: Colors.black38),
                    ),
                  Positioned(
                    left: 6,
                    bottom: 4,
                    child: Text(
                      '${c.length}b${c.loops > 1 ? ' ×${c.loops}' : ''}',
                      style: const TextStyle(
                        color: Colors.black87,
                        fontSize: 11,
                      ),
                    ),
                  ),
                  handle('left', left: 0),
                  handle('right', right: 0),
                  handle('loop', right: 0, top: 0, height: 14, width: 14),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Grid extends CustomPainter {
  _Grid(this.zoom, this.color);
  final double zoom;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final beat = Paint()..color = color.withValues(alpha: 0.35);
    final bar = Paint()..color = color;
    for (var b = 0; b * zoom < size.width; b++) {
      canvas.drawRect(
        Rect.fromLTWH(b * zoom, 0, 1, size.height),
        b % 4 == 0 ? bar : beat,
      );
    }
  }

  @override
  bool shouldRepaint(_Grid o) => o.zoom != zoom || o.color != color;
}
