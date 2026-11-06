import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/discovery.dart';
import '../core/export.dart';
import '../core/library.dart';
import '../core/library_edit.dart';
import 'format.dart';
import 'library_screen.dart' show EnergyMeter, Stars;
import 'player.dart';
import 'state.dart';
import 'theme.dart';
import 'widgets.dart';

/// The right-hand detail pane for one track (1.x TrackDetail).
class TrackDetailPane extends ConsumerStatefulWidget {
  const TrackDetailPane({
    super.key,
    required this.id,
    required this.onClose,
    this.onWrite,
  });
  final int id;
  final VoidCallback onClose;
  final ValueChanged<int>? onWrite;
  @override
  ConsumerState<TrackDetailPane> createState() => _TrackDetailPaneState();
}

class _TrackDetailPaneState extends ConsumerState<TrackDetailPane> {
  final form = <String, TextEditingController>{};
  String clean = '';
  final tagCtl = TextEditingController();
  int _loadedVersion = -1;

  void _fill(Map<String, Object?> mine) {
    for (final k in [
      'genre',
      'year',
      'bpm',
      'key',
      'mood',
      'notes',
      'version_label',
    ]) {
      (form[k] ??= TextEditingController()).text = mine[k] == null
          ? ''
          : '${mine[k]}';
    }
    clean = '${mine['clean_explicit'] ?? ''}';
  }

  void _patch(Map<String, Object?> p, {String? done}) => guard(
    () => ref.read(sessionProvider).library.updateUserFields([widget.id], p),
    done: done,
    bump: ref,
  );

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(sessionProvider);
    final version = ref.watch(versionProvider);
    final notation = '${ref.watch(settingsProvider)['key_notation']}';
    final t = DjTokens.of(context);
    final Map<String, Object?> d;
    try {
      d = s.library.trackDetail(widget.id);
    } on Object catch (e) {
      return Card(child: Center(child: Text('$e')));
    }
    final row = d['row']! as TrackRow;
    final file = (d['file'] as Map?)?.cast<String, Object?>() ?? const {};
    final mine = (d['mine'] as Map?)?.cast<String, Object?>() ?? const {};
    final a = (d['analysis'] as Map?)?.cast<String, Object?>();
    if (_loadedVersion != version) {
      _loadedVersion = version;
      _fill(mine);
    }
    final sugg = s.suggestions.list(status: 'pending', trackId: widget.id);
    Widget section(String title, List<Widget> kids) => Padding(
      padding: const EdgeInsets.only(top: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          ...kids,
        ],
      ),
    );
    Widget kv(String k, Widget v) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(k, style: TextStyle(color: t.faint)),
          ),
          Expanded(child: v),
        ],
      ),
    );
    Widget field(
      String k,
      String label,
      Object? fileVal, {
      bool area = false,
    }) => SizedBox(
      width: area ? 360 : 170,
      child: TextField(
        controller: form[k],
        maxLines: area ? 3 : 1,
        decoration: InputDecoration(
          labelText: label,
          hintText: fileVal != null && fileVal != ''
              ? 'File: $fileVal'
              : 'Unknown',
        ),
      ),
    );
    return Card(
      margin: const EdgeInsets.fromLTRB(0, 12, 12, 12),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      row.title ?? row.fileName,
                      style: Theme.of(context).textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    Text(fmtText(row.artist), style: TextStyle(color: t.muted)),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Close details',
                onPressed: widget.onClose,
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          const SizedBox(height: 8),
          PreviewPlayer(path: row.path, durationMs: row.durationMs),
          if (d['read_error'] != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                "Could not read this file: ${d['read_error']}. The file was not changed.",
                style: TextStyle(color: t.warn),
              ),
            ),
          if (a != null && a['status'] == 'ok')
            section('Analysis (estimates)', [
              SizedBox(
                height: 64,
                child: Waveform(
                  peaks: (a['waveform'] as List?)?.cast<int>() ?? const [],
                  cues: a,
                ),
              ),
              kv(
                'BPM',
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      '${fmtBpm(a['bpm'] as num?)}${a['bpm_alt'] != null ? ' (or ${fmtBpm(a['bpm_alt'] as num?)})' : ''}  ',
                    ),
                    Text(
                      'conf. ${(((a['bpm_confidence'] as num?) ?? 0) * 100).round()}%',
                      style: TextStyle(color: t.faint, fontSize: DjType.small),
                    ),
                    if (a['bpm'] != null)
                      TextButton(
                        onPressed: () => _patch({'bpm': a['bpm']}),
                        child: const Text('Use'),
                      ),
                  ],
                ),
              ),
              kv(
                'Key',
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      fmtKey(
                        a['camelot'] as String? ?? a['key'] as String?,
                        notation,
                      ),
                    ),
                    if (a['camelot'] != null)
                      TextButton(
                        onPressed: () => _patch({'key': a['camelot']}),
                        child: const Text('Use'),
                      ),
                  ],
                ),
              ),
              kv(
                'Energy',
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text('${fmtText(a['energy'])}/10'),
                    if (a['energy'] != null)
                      TextButton(
                        onPressed: () => _patch({'energy': a['energy']}),
                        child: const Text('Use'),
                      ),
                  ],
                ),
              ),
              kv(
                'Loudness',
                Text(
                  '${a['loudness_lufs'] != null ? '${(a['loudness_lufs']! as num).toStringAsFixed(1)} LUFS' : unknown} · peak ${a['peak_dbfs'] ?? unknown} dBFS',
                ),
              ),
              kv(
                'Intro / outro',
                Text(
                  '${fmtDuration(((a['intro_end_ms'] as int?) ?? 0) - ((a['silence_start_ms'] as int?) ?? 0))} / '
                  '${a['outro_start_ms'] != null && a['duration_ms'] != null ? fmtDuration((a['duration_ms']! as int) - ((a['silence_end_ms'] as int?) ?? 0) - (a['outro_start_ms']! as int) + ((a['silence_end_ms'] as int?) ?? 0)) : unknown}',
                ),
              ),
              kv(
                'Cue ideas',
                Text(
                  [
                    for (final c in (a['cues'] as List?) ?? const [])
                      '${(c as Map)['label']} ${fmtDuration(c['ms'] as int?)}',
                  ].join(' · ').ifEmpty(unknown),
                ),
              ),
              for (final w in (a['warnings'] as List?) ?? const [])
                Text(
                  '$w',
                  style: TextStyle(color: t.warn, fontSize: DjType.small),
                ),
              Text(
                "Estimates from ${a['method']} v${a['version']}. They can be wrong (half/double tempo, modal keys) — your values always win. Serato's own cues and beatgrids are not read or changed.",
                style: TextStyle(color: t.faint, fontSize: DjType.small),
              ),
            ])
          else
            section('Analysis', [
              Text(
                a?['status'] == 'error'
                    ? 'Could not analyse: ${a!['error']}'
                    : 'Not analysed yet.',
                style: TextStyle(color: t.faint),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: () => guard(
                    () => s.startAnalysis(ids: [widget.id], force: true),
                    done: 'Analysing in the background…',
                  ),
                  icon: const Icon(Icons.speed, size: 16),
                  label: const Text('Analyse this track'),
                ),
              ),
            ]),
          if (sugg.isNotEmpty)
            section('Suggestions (${sugg.length})', [
              for (final x in sugg)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    '${x.field}: ${x.currentValue ?? '∅'} → ${x.suggestedValue}',
                  ),
                  subtitle: Text(
                    '${x.source} · ${(((x.confidence ?? 0) * 100).round())}% · ${x.evidence ?? ''}',
                    style: const TextStyle(fontSize: DjType.caption),
                  ),
                  trailing: Wrap(
                    children: [
                      TextButton(
                        onPressed: () =>
                            guard(() => s.suggestions.accept(x.id), bump: ref),
                        child: const Text('Accept'),
                      ),
                      IconButton(
                        tooltip: 'Reject',
                        onPressed: () =>
                            guard(() => s.suggestions.reject(x.id), bump: ref),
                        icon: const Icon(Icons.close, size: 16),
                      ),
                    ],
                  ),
                ),
            ]),
          section('Energy and rating (your catalogue)', [
            Row(
              children: [
                EnergyMeter(
                  big: true,
                  value: mine['energy'] as int?,
                  onChanged: (v) => _patch({'energy': v}),
                ),
                const SizedBox(width: 10),
                Text(
                  mine['energy'] != null ? '${mine['energy']}/10' : 'Not rated',
                  style: TextStyle(color: t.faint),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                SizedBox(
                  width: 60,
                  child: Text('Rating', style: TextStyle(color: t.faint)),
                ),
                Stars(
                  value: mine['rating'] as int?,
                  onChanged: (v) => _patch({'rating': v}),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                SizedBox(
                  width: 60,
                  child: Text('Colour', style: TextStyle(color: t.faint)),
                ),
                for (final c in [null, ...crateColors.keys])
                  InkWell(
                    onTap: () => _patch({'color': c}),
                    child: Padding(
                      padding: const EdgeInsets.all(3),
                      child: Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: mine['color'] == c
                                ? t.accent
                                : Colors.transparent,
                            width: 2,
                          ),
                        ),
                        padding: const EdgeInsets.all(2),
                        child: ColorDot(c, size: 14),
                      ),
                    ),
                  ),
              ],
            ),
          ]),
          section('Tags', [
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final tg in row.tags)
                  InputChip(
                    label: Text(tg),
                    onDeleted: () => guard(
                      () => s.library.setTags([widget.id], remove: [tg]),
                      bump: ref,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            TextField(
              controller: tagCtl,
              decoration: const InputDecoration(
                hintText: 'Add a tag (e.g. Wedding, Peak time)',
              ),
              onSubmitted: (v) {
                if (v.trim().isEmpty) return;
                guard(
                  () => s.library.setTags([widget.id], add: [v.trim()]),
                  bump: ref,
                );
                tagCtl.clear();
              },
            ),
          ]),
          section('My catalogue values', [
            Text(
              'These override what the app shows and filters on. They are stored only in DJ Assistant and are never written to the music file or to Serato.',
              style: TextStyle(color: t.faint, fontSize: DjType.small),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                field('genre', 'Genre', file['genre']),
                field('year', 'Year', file['year']),
                field('bpm', 'BPM', file['bpm']),
                field('key', 'Key', file['key']),
                field('mood', 'Mood', null),
                field('version_label', 'Version label', file['version_hint']),
                SizedBox(
                  width: 170,
                  child: DropdownButtonFormField<String>(
                    isExpanded: true,
                    style: Theme.of(context).textTheme.bodyMedium,
                    initialValue: clean,
                    decoration: const InputDecoration(
                      labelText: 'Clean / explicit',
                    ),
                    items: [
                      DropdownMenuItem(
                        value: '',
                        child: Text(
                          file['clean_hint'] != null
                              ? 'From title: ${file['clean_hint']}'
                              : 'Unknown',
                        ),
                      ),
                      const DropdownMenuItem(
                        value: 'clean',
                        child: Text('Clean'),
                      ),
                      const DropdownMenuItem(
                        value: 'explicit',
                        child: Text('Explicit'),
                      ),
                    ],
                    onChanged: (v) => clean = v ?? '',
                  ),
                ),
                field('notes', 'Notes', null, area: true),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              children: [
                FilledButton(
                  onPressed: () {
                    String? txt(String k) => form[k]!.text.trim().isEmpty
                        ? null
                        : form[k]!.text.trim();
                    _patch(
                      {
                        for (final k in [
                          'genre',
                          'key',
                          'mood',
                          'notes',
                          'version_label',
                        ])
                          k: txt(k),
                        'year': txt('year') == null
                            ? null
                            : int.tryParse(txt('year')!),
                        'bpm': txt('bpm') == null
                            ? null
                            : double.tryParse(txt('bpm')!),
                        'clean_explicit': clean.isEmpty ? null : clean,
                      },
                      done: 'Saved to your catalogue. The music file was not changed.',
                    );
                  },
                  child: const Text('Save to catalogue'),
                ),
                if (widget.onWrite != null)
                  OutlinedButton(
                    onPressed: () => widget.onWrite!(widget.id),
                    child: const Text('Write tags to file…'),
                  ),
              ],
            ),
          ]),
          section('File', [
            kv('File', SelectableText(row.fileName)),
            kv(
              'Format',
              Text(
                '${fmtText(row.format)}${row.bitrateKbps != null ? ' · ${row.bitrateKbps} kbps' : ''}',
              ),
            ),
            kv('Size', Text(fmtBytes(row.fileSize))),
            kv('Length', Text(fmtDuration(row.durationMs))),
            kv(
              'Crates',
              Text(
                [
                  for (final c in (d['crates'] as List?) ?? const [])
                    '${(c as Map)['name']}',
                ].join(', ').ifEmpty(unknown),
              ),
            ),
            kv('Plays', Text('${d['plays'] ?? 0}')),
            Wrap(
              spacing: 8,
              children: [
                TextButton.icon(
                  onPressed: () => revealInFolder(row.path),
                  icon: const Icon(Icons.folder_open, size: 16),
                  label: const Text('Show in folder'),
                ),
                TextButton.icon(
                  onPressed: () => _stores(context, row),
                  icon: const Icon(Icons.storefront_outlined, size: 16),
                  label: const Text('Find in stores'),
                ),
              ],
            ),
          ]),
        ],
      ),
    );
  }

  void _stores(BuildContext context, TrackRow row) => showDialog<void>(
    context: context,
    builder: (c) => SimpleDialog(
      title: const Text('Buy or preview'),
      children: [
        for (final l in storeLinks(row.artist ?? '', row.title ?? row.fileName))
          SimpleDialogOption(
            onPressed: () => openUrl(l['url']!),
            child: Text(l['store']!),
          ),
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'Links only: nothing is downloaded or sent until you open one.',
          ),
        ),
      ],
    ),
  );
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

/// The analysis waveform (0–255 peaks) with cue markers.
class Waveform extends StatelessWidget {
  const Waveform({super.key, required this.peaks, this.cues, this.position});
  final List<int> peaks;
  final Map<String, Object?>? cues;
  final double? position;
  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _WavePainter(peaks, DjTokens.of(context), cues, position),
    size: Size.infinite,
  );
}

class _WavePainter extends CustomPainter {
  _WavePainter(this.peaks, this.t, this.a, this.position);
  final List<int> peaks;
  final DjTokens t;
  final Map<String, Object?>? a;
  final double? position;
  @override
  void paint(Canvas canvas, Size size) {
    if (peaks.isEmpty) return;
    final p = Paint()
      ..color = t.accent.withValues(alpha: 0.8)
      ..strokeWidth = 1;
    final mid = size.height / 2;
    final step = size.width / peaks.length;
    for (var i = 0; i < peaks.length; i++) {
      final h = peaks[i] / 255 * mid;
      canvas.drawLine(Offset(i * step, mid - h), Offset(i * step, mid + h), p);
    }
    final dur = a?['duration_ms'] as int?;
    if (dur != null && dur > 0) {
      final cue = Paint()..color = t.warn;
      for (final c in (a?['cues'] as List?) ?? const []) {
        final x = ((c as Map)['ms'] as int) / dur * size.width;
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), cue);
      }
    }
    if (position != null) {
      final x = position!.clamp(0, 1) * size.width;
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        Paint()
          ..color = Colors.white
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WavePainter old) =>
      old.peaks != peaks || old.position != position;
}
