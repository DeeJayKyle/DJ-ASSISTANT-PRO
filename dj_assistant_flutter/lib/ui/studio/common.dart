import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show KeyDownEvent, KeyRepeatEvent, LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../assistant/ai_config.dart';
import '../../assistant/quick_ai.dart';
import '../../core/export.dart';
import '../../core/library.dart';
import '../../core/packs.dart';
import '../../studio/audio_out.dart' show PcmStream;
import '../../studio/engine.dart';
import '../../studio/stems_cache.dart';
import '../state.dart';
import '../theme.dart';

/// One Studio engine for the app (decoded songs and stems are shared by the
/// Stems, Remix and DJ pages).
final studioEngineProvider = Provider<StudioEngine>((ref) => StudioEngine());

/// Settings → Studio and → Limits, applied every time a page uses the engine
/// (so a change takes effect without a restart).
StudioEngine applyStudioSettings(WidgetRef ref, StudioEngine e) {
  final st = ref.read(settingsProvider);
  PcmStream.defaultLead = ((st['audio_buffer_ms'] as int?) ?? 120) / 1000;
  return e
    ..maxMinutes = userLimit(ref, 'studio_minutes')
    ..cores = st['studio_cores'] as int?
    ..useGpu = st['ai_gpu'] != false
    ..stemsCache = st['stems_cache'] == false
        ? null
        : StemsCache(
            preparedStemsDir(ref),
            maxBytes:
                ((st['stems_cache_gb'] as int?) ?? 20) * StemsCache.gigabyte,
          );
}

/// Prepared stems are shared by every account on this computer, like packs.
String preparedStemsDir(WidgetRef ref) =>
    p.join(ref.read(accountsProvider).base, 'stems-cache');

/// Songs already split this session (shown with a "stems" badge).
class SplitSongs extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};
  void mark(String id) => state = {...state, id};
}

final splitSongsProvider = NotifierProvider<SplitSongs, Set<String>>(
  SplitSongs.new,
);

/// A song handed from one Studio page to another ("Remix it →", "DJ it →").
class StudioHandoff {
  const StudioHandoff(this.page, this.song, this.at, {this.method});
  final String page;
  final SongRef song;
  final int at;

  /// For Stems: 'fast' or 'ai' (null: the page's current choice).
  final String? method;
}

class Handoff extends Notifier<StudioHandoff?> {
  @override
  StudioHandoff? build() => null;
  void send(String page, SongRef s, {String? method}) => state = StudioHandoff(
    page,
    s,
    DateTime.now().microsecondsSinceEpoch,
    method: method,
  );
}

final handoffProvider = NotifierProvider<Handoff, StudioHandoff?>(Handoff.new);

SongRef songOf(TrackRow r) => SongRef(
  id: '${r.id}',
  title: r.title?.trim().isNotEmpty == true ? r.title! : r.fileName,
  path: r.path,
  artist: r.artist,
  bpm: r.bpm,
  key: r.key,
);

/// The installed Pro Stems AI model, or null.
String? aiStemsModel(WidgetRef ref) => packFilePath(
  ref.read(accountsProvider).base,
  'stems-ai',
  'htdemucs_embedded.onnx',
);

/// The assistant's model for sound design, or null when AI is off.
Future<String> Function(String, String)? studioAi(WidgetRef ref) {
  final s = ref.read(sessionProvider);
  if (llmConfig(s.cat, s.secrets).provider == 'off') return null;
  return AiHelpers(s).complete;
}

String fmtTime(double s) =>
    '${s ~/ 60}:${(s % 60).floor().toString().padLeft(2, '0')}';

String errText(Object e) {
  final s = '$e';
  return s.startsWith('Exception: ') ? s.substring(11) : s;
}

String safeName(String s) {
  final t = s
      .replaceAll(RegExp(r'[\\/:*?"<>|]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return t.isEmpty ? 'Song' : t;
}

/// Saves one new Studio file where the DJ chooses (never overwriting a song).
Future<String?> saveStudioFile(String suggested, Uint8List bytes) async {
  final ext = p.extension(suggested).replaceFirst('.', '');
  final loc = await getSaveLocation(
    suggestedName: suggested,
    acceptedTypeGroups: [
      XTypeGroup(label: ext.toUpperCase(), extensions: [ext]),
    ],
  );
  if (loc == null) return null;
  var path = loc.path;
  if (p.extension(path).isEmpty) path = '$path.$ext';
  studioSave(path, bytes);
  return path;
}

/// Saves several files into a NEW folder inside the one the DJ chooses.
Future<String?> saveStudioFiles(
  String folderName,
  List<(String, Uint8List)> files,
) async {
  final parent = await getDirectoryPath(confirmButtonText: 'Save here');
  if (parent == null) return null;
  final dir = studioNewFolder(parent, folderName);
  for (final (name, bytes) in files) {
    studioWriteInto(dir, name, bytes);
  }
  return dir;
}

/// A titled card in the Studio.
class StudioPanel extends StatelessWidget {
  const StudioPanel({
    super.key,
    this.title,
    this.trailing,
    required this.child,
  });
  final String? title;
  final List<Widget>? trailing;
  final Widget child;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title != null || trailing != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 6,
                children: [
                  if (title != null)
                    Text(
                      title!,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: DjType.title,
                      ),
                    ),
                  ...?trailing,
                ],
              ),
            ),
          child,
        ],
      ),
    ),
  );
}

/// A labelled slider ("knob").
class Knob extends StatelessWidget {
  const Knob({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.format,
    this.onEnd,
    this.width = 170,
  });
  final String label;
  final double value, min, max, width;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onEnd;
  final String Function(double)? format;
  @override
  Widget build(BuildContext context) {
    final t = DjTokens.of(context);
    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$label  ${format?.call(value) ?? value.toStringAsFixed(2)}',
            style: TextStyle(fontSize: DjType.small, color: t.muted),
          ),
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChanged: onChanged,
            onChangeEnd: onEnd,
          ),
        ],
      ),
    );
  }
}

/// Searchable list of library songs.
class SongPicker extends ConsumerStatefulWidget {
  const SongPicker({
    super.key,
    required this.onPick,
    this.label = 'Choose a song',
    this.height = 360,
  });
  final ValueChanged<SongRef> onPick;
  final String label;
  final double height;
  @override
  ConsumerState<SongPicker> createState() => _SongPickerState();
}

class _SongPickerState extends ConsumerState<SongPicker> {
  String q = '';
  Timer? _debounce;
  List<TrackRow> rows = const [];

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
    final s = ref.read(sessionProvider);
    try {
      rows = s.library
          .search(
            TrackQuery(
              text: q.trim().isEmpty ? null : q,
              limit: userLimit(ref, 'picker_results') ?? TrackQuery.all,
            ),
          )
          .rows;
    } on Object {
      rows = const [];
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(versionProvider, (_, _) => _load());
    final t = DjTokens.of(context);
    final split = ref.watch(splitSongsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          decoration: InputDecoration(
            hintText: 'Search songs',
            prefixIcon: const Icon(Icons.search, size: 18),
            isDense: true,
            labelText: widget.label,
          ),
          onChanged: (v) {
            q = v;
            _debounce?.cancel();
            _debounce = Timer(const Duration(milliseconds: 150), _load);
          },
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: widget.height,
          child: rows.isEmpty
              ? Center(
                  child: Text(
                    q.isEmpty ? 'No songs yet.' : 'No songs match.',
                    style: TextStyle(color: t.faint),
                  ),
                )
              : ListView.builder(
                  itemCount: rows.length,
                  itemBuilder: (_, i) {
                    final r = rows[i];
                    final song = songOf(r);
                    return ListTile(
                      dense: true,
                      title: Row(
                        children: [
                          Flexible(
                            child: Text(
                              song.title,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (split.contains(song.id))
                            Padding(
                              padding: const EdgeInsets.only(left: 6),
                              child: Text(
                                'stems',
                                style: TextStyle(
                                  color: t.accent,
                                  fontSize: DjType.caption,
                                ),
                              ),
                            ),
                        ],
                      ),
                      subtitle: Text(
                        [
                          ?r.artist,
                          if (r.bpm != null) '${r.bpm!.round()} BPM',
                          ?r.key,
                        ].join(' · '),
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => widget.onPick(song),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// Waveform overview with a playhead and optional markers; tap to seek.
class WaveView extends StatelessWidget {
  const WaveView({
    super.key,
    required this.peaks,
    required this.progress,
    this.onSeek,
    this.markers = const [],
    this.height = 56,
    this.color,
  });
  final Float32List peaks;
  final double progress, height;
  final ValueChanged<double>? onSeek;
  final List<(double, String)> markers;
  final Color? color;
  @override
  Widget build(BuildContext context) {
    final t = DjTokens.of(context);
    return LayoutBuilder(
      builder: (_, c) => GestureDetector(
        onTapDown: onSeek == null
            ? null
            : (d) => onSeek!((d.localPosition.dx / c.maxWidth).clamp(0, 1)),
        onHorizontalDragUpdate: onSeek == null
            ? null
            : (d) => onSeek!((d.localPosition.dx / c.maxWidth).clamp(0, 1)),
        child: Semantics(
          label: 'Waveform',
          value: '${(progress * 100).round()}%',
          child: CustomPaint(
            size: Size(c.maxWidth, height),
            painter: _WavePainter(
              peaks,
              progress,
              markers,
              color ?? t.accent,
              t.line,
              t.muted,
              Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  _WavePainter(
    this.peaks,
    this.progress,
    this.markers,
    this.on,
    this.off,
    this.mark,
    this.head,
  );
  final Float32List peaks;
  final double progress;
  final List<(double, String)> markers;
  final Color on, off, mark, head;

  @override
  void paint(Canvas canvas, Size size) {
    final n = peaks.isEmpty ? 1 : peaks.length;
    final w = size.width / n;
    final pOn = Paint()..color = on, pOff = Paint()..color = off;
    for (var i = 0; i < peaks.length; i++) {
      final h = (peaks[i] * (size.height - 6)).clamp(1.0, size.height);
      canvas.drawRect(
        Rect.fromLTWH(
          i * w,
          (size.height - h) / 2,
          (w - 0.5).clamp(1.0, 99),
          h,
        ),
        i / n < progress ? pOn : pOff,
      );
    }
    final pm = Paint()..color = mark;
    for (final (at, label) in markers) {
      final x = at * size.width;
      canvas.drawRect(Rect.fromLTWH(x, 0, 1, 6), pm);
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(color: mark, fontSize: DjType.caption),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(x + 2, 0));
    }
    canvas.drawRect(
      Rect.fromLTWH(progress * size.width, 0, 1.5, size.height),
      Paint()..color = head,
    );
  }

  @override
  bool shouldRepaint(_WavePainter o) =>
      o.peaks != peaks ||
      o.progress != progress ||
      o.markers != markers ||
      o.on != on;
}

/// A toggle chip.
Widget chip(String label, bool on, VoidCallback? onTap, {String? tooltip}) {
  final c = FilterChip(
    label: Text(label),
    selected: on,
    onSelected: onTap == null ? null : (_) => onTap(),
    visualDensity: VisualDensity.compact,
  );
  return tooltip == null ? c : Tooltip(message: tooltip, child: c);
}

/// Progress with a label.
class StudioProgress extends StatelessWidget {
  const StudioProgress(this.label, this.value, {super.key});
  final String label;
  final double? value;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: TextStyle(color: DjTokens.of(context).muted)),
        const SizedBox(height: 4),
        LinearProgressIndicator(value: value),
      ],
    ),
  );
}

/// A small rotary knob for the mixer: drag up or down (or scroll) to turn,
/// double-tap to reset to [reset]. Arrow keys work when it has focus.
class RotaryKnob extends StatelessWidget {
  const RotaryKnob({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.reset,
    this.format,
    this.size = 44,
    this.bipolar = false,
  });
  final String label;
  final double value, min, max, size;
  final double? reset;
  final ValueChanged<double> onChanged;
  final String Function(double)? format;

  /// Draw the arc from the centre (EQ, filter) rather than from the left.
  final bool bipolar;

  void _nudge(double frac) =>
      onChanged((value + frac * (max - min)).clamp(min, max));

  @override
  Widget build(BuildContext context) {
    final t = DjTokens.of(context);
    final text = format?.call(value) ?? value.toStringAsFixed(1);
    return Semantics(
      label: label,
      value: text,
      slider: true,
      increasedValue: format?.call((value + (max - min) / 20).clamp(min, max)),
      decreasedValue: format?.call((value - (max - min) / 20).clamp(min, max)),
      onIncrease: () => _nudge(0.05),
      onDecrease: () => _nudge(-0.05),
      child: Focus(
        onKeyEvent: (_, e) {
          if (e is! KeyDownEvent && e is! KeyRepeatEvent) {
            return KeyEventResult.ignored;
          }
          if (e.logicalKey == LogicalKeyboardKey.arrowUp ||
              e.logicalKey == LogicalKeyboardKey.arrowRight) {
            _nudge(0.05);
            return KeyEventResult.handled;
          }
          if (e.logicalKey == LogicalKeyboardKey.arrowDown ||
              e.logicalKey == LogicalKeyboardKey.arrowLeft) {
            _nudge(-0.05);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Listener(
          onPointerSignal: (s) {
            if (s is PointerScrollEvent) _nudge(-s.scrollDelta.dy / 2000);
          },
          child: GestureDetector(
            onVerticalDragUpdate: (d) => _nudge(-d.delta.dy / 160),
            onDoubleTap: reset == null ? null : () => onChanged(reset!),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: size,
                  height: size,
                  child: CustomPaint(
                    painter: _KnobPainter(
                      frac: max == min ? 0 : (value - min) / (max - min),
                      origin: bipolar
                          ? (((reset ?? 0) - min) / (max - min)).clamp(0, 1)
                          : 0,
                      track: t.line,
                      fill: t.accent,
                      face: t.panel2,
                      tick: t.text,
                    ),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  label,
                  style: TextStyle(fontSize: DjType.caption, color: t.muted),
                ),
                Text(
                  text,
                  style: TextStyle(fontSize: DjType.caption, color: t.faint),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _KnobPainter extends CustomPainter {
  _KnobPainter({
    required this.frac,
    required this.origin,
    required this.track,
    required this.fill,
    required this.face,
    required this.tick,
  });
  final double frac, origin;
  final Color track, fill, face, tick;

  // 270° of travel, starting at the lower left
  static const _start = 0.75 * math.pi, _sweep = 1.5 * math.pi;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2 - 3;
    final rect = Rect.fromCircle(center: c, radius: r);
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, _start, _sweep, false, stroke..color = track);
    final a = _start + origin * _sweep, b = _start + frac * _sweep;
    canvas.drawArc(
      rect,
      math.min(a, b),
      (b - a).abs(),
      false,
      stroke..color = fill,
    );
    canvas.drawCircle(c, r - 6, Paint()..color = face);
    final p = c + Offset(math.cos(b), math.sin(b)) * (r - 9);
    canvas.drawLine(
      c,
      p,
      Paint()
        ..color = tick
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_KnobPainter o) =>
      o.frac != frac ||
      o.origin != origin ||
      o.fill != fill ||
      o.track != track;
}
