import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/next_track.dart';
import '../core/text.dart';
import 'format.dart';
import 'state.dart';
import 'theme.dart';
import 'track_detail.dart';
import 'widgets.dart';

/// The whole library on one chart: tempo across, energy up, each track a dot
/// coloured by its key on the Camelot wheel. Search lights up matching
/// tracks; click a dot to open the track. Tracks without a BPM or energy
/// are counted but not drawn.
class LibraryMapScreen extends ConsumerStatefulWidget {
  const LibraryMapScreen({super.key});
  @override
  ConsumerState<LibraryMapScreen> createState() => _LibraryMapScreenState();
}

class MapPoint {
  const MapPoint(this.c, this.x, this.y);
  final NextTrackCandidate c;

  /// 0–1 across (tempo) and up (energy), before the chart's padding.
  final double x, y;
}

const mapBpmMin = 60.0, mapBpmMax = 180.0;

/// Places tracks on the map. Half-time tracks below 60 BPM are doubled and
/// very fast ones halved so they sit with what they mix with. A small
/// jitter, fixed per track, keeps tracks with equal values from stacking.
List<MapPoint> mapPoints(List<NextTrackCandidate> lib) {
  final out = <MapPoint>[];
  for (final c in lib) {
    final raw = c.bpm;
    final e = c.energy;
    if (raw == null || raw <= 0 || e == null) continue;
    var b = raw;
    while (b < mapBpmMin) {
      b *= 2;
    }
    while (b > mapBpmMax) {
      b /= 2;
    }
    final r = math.Random(c.id);
    final jx = (r.nextDouble() - 0.5) * 0.004;
    final jy = (r.nextDouble() - 0.5) * 0.06;
    out.add(
      MapPoint(
        c,
        ((b - mapBpmMin) / (mapBpmMax - mapBpmMin) + jx).clamp(0, 1),
        ((e - 1) / 9 + jy).clamp(0, 1),
      ),
    );
  }
  return out;
}

/// A colour per Camelot code: the number picks the hue round the wheel,
/// minor (A) keys are a little deeper than major (B).
Color keyColor(String? key) {
  final k = camelotParts(key);
  if (k == null) return const Color(0xFF8A8F98);
  final hue = ((k.$1 - 1) * 30.0) % 360;
  return HSLColor.fromAHSL(1, hue, 0.72, k.$2 ? 0.5 : 0.66).toColor();
}

class _LibraryMapScreenState extends ConsumerState<LibraryMapScreen> {
  final search = TextEditingController();
  int? selected;

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(sessionProvider);
    ref.watch(versionProvider);
    final t = DjTokens.of(context);
    final lib = NextTrackService(s.cat).candidates();
    final points = mapPoints(lib);
    final q = fold(search.text.trim());
    final hits = q.isEmpty
        ? null
        : {
            for (final p in points)
              if (fold(p.c.label).contains(q)) p.c.id,
          };
    final chart = Panel(
      title: 'Tempo × energy',
      subtitle:
          '${points.length} of ${lib.length} tracks on the map'
          '${lib.length > points.length ? ' · ${lib.length - points.length} need a BPM and energy (run analysis)' : ''}'
          '${hits == null ? '' : ' · ${hits.length} match'}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: search,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Light up an artist, title or genre word',
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 460,
            child: LayoutBuilder(
              builder: (context, box) {
                final size = Size(box.maxWidth, box.maxHeight);
                return GestureDetector(
                  onTapUp: (d) {
                    final id = _nearest(points, d.localPosition, size);
                    setState(() => selected = id);
                  },
                  child: CustomPaint(
                    size: size,
                    painter: _MapPainter(
                      points,
                      hits: hits,
                      selected: selected,
                      grid: t.faint,
                      text: t.muted,
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 4,
            children: [
              for (var n = 1; n <= 12; n++)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircleAvatar(radius: 5, backgroundColor: keyColor('${n}A')),
                    const SizedBox(width: 2),
                    CircleAvatar(radius: 5, backgroundColor: keyColor('${n}B')),
                    const SizedBox(width: 4),
                    Text('$n', style: TextStyle(color: t.muted)),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
    return PageFrame(
      title: 'Library Map',
      subtitle: 'Every analysed track by tempo and energy, coloured by key. Neighbouring colours on the Camelot wheel mix well.',
      child: selected == null
          ? chart
          : Wrap(
              spacing: 16,
              runSpacing: 16,
              children: [
                SizedBox(width: 760, child: chart),
                SizedBox(
                  width: 420,
                  height: 640,
                  child: TrackDetailPane(
                    key: ValueKey(selected),
                    id: selected!,
                    onClose: () => setState(() => selected = null),
                  ),
                ),
              ],
            ),
    );
  }

  int? _nearest(List<MapPoint> pts, Offset at, Size size) {
    int? best;
    var bestD = 18.0 * 18.0;
    for (final p in pts) {
      final o = _MapPainter.place(p, size);
      final d = (o - at).distanceSquared;
      if (d < bestD) {
        bestD = d;
        best = p.c.id;
      }
    }
    return best;
  }
}

class _MapPainter extends CustomPainter {
  _MapPainter(
    this.points, {
    required this.hits,
    required this.selected,
    required this.grid,
    required this.text,
  });
  final List<MapPoint> points;
  final Set<int>? hits;
  final int? selected;
  final Color grid, text;

  static const pad = EdgeInsets.fromLTRB(36, 8, 8, 24);

  static Offset place(MapPoint p, Size s) => Offset(
    pad.left + p.x * (s.width - pad.horizontal),
    pad.top + (1 - p.y) * (s.height - pad.vertical),
  );

  void _label(Canvas c, String s, Offset at) {
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(fontFamily: DjType.family, color: text, fontSize: 11),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, at - Offset(tp.width / 2, 0));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = grid.withValues(alpha: 0.35)
      ..strokeWidth = 1;
    final w = size.width - pad.horizontal, h = size.height - pad.vertical;
    for (var b = mapBpmMin; b <= mapBpmMax; b += 20) {
      final x = pad.left + (b - mapBpmMin) / (mapBpmMax - mapBpmMin) * w;
      canvas.drawLine(Offset(x, pad.top), Offset(x, pad.top + h), line);
      _label(canvas, '${b.round()}', Offset(x, pad.top + h + 4));
    }
    for (var e = 1; e <= 10; e += 3) {
      final y = pad.top + (1 - (e - 1) / 9) * h;
      canvas.drawLine(Offset(pad.left, y), Offset(pad.left + w, y), line);
      _label(canvas, 'E$e', Offset(pad.left - 16, y - 7));
    }
    final dot = Paint();
    // dimmed tracks first, so the lit ones sit on top
    for (final pass in [false, true]) {
      for (final p in points) {
        final lit = hits == null || hits!.contains(p.c.id);
        if (lit != pass) continue;
        dot.color = keyColor(p.c.camelot).withValues(alpha: lit ? 0.9 : 0.15);
        canvas.drawCircle(place(p, size), lit && hits != null ? 4.5 : 3.2, dot);
      }
    }
    final sel = points.where((p) => p.c.id == selected).firstOrNull;
    if (sel != null) {
      final o = place(sel, size);
      canvas.drawCircle(
        o,
        8,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = text,
      );
      final tp = TextPainter(
        text: TextSpan(
          text:
              '${sel.c.label} · ${fmtBpm(sel.c.bpm)} BPM · ${sel.c.camelot ?? '?'}',
          style: TextStyle(
            fontFamily: DjType.family,
            color: text,
            fontSize: 12,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: math.max(120, size.width / 2));
      final x = (o.dx + 10).clamp(0.0, size.width - tp.width);
      tp.paint(canvas, Offset(x, math.max(0, o.dy - 22)));
    }
  }

  @override
  bool shouldRepaint(_MapPainter old) =>
      old.points != points || old.hits != hits || old.selected != selected;
}
