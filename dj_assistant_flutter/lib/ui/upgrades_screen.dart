import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/discovery.dart' show storeLinks;
import '../core/library_edit.dart';
import '../core/limits.dart' show upTo;
import '../core/upgrades.dart';
import 'format.dart';
import 'organise_preview.dart';
import 'player.dart';
import 'state.dart';
import 'theme.dart';
import 'widgets.dart';

/// Low-bitrate tracks and their possible upgrades: copies already owned,
/// legitimate store searches (links only), and a side-by-side listening
/// comparison before anything is replaced (through Organise Files).
class UpgradesScreen extends ConsumerStatefulWidget {
  const UpgradesScreen({super.key});
  @override
  ConsumerState<UpgradesScreen> createState() => _UpgradesScreenState();
}

class _UpgradesScreenState extends ConsumerState<UpgradesScreen> {
  bool showKept = false;

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(sessionProvider);
    ref.watch(versionProvider);
    final t = DjTokens.of(context);
    final up = UpgradeService(s.cat);
    final ids = up.lowBitrateIds(includeKept: showKept);
    final kept = up.keptCount();
    final keptIds = up.keptIds();
    final shown = upTo(ids, listRows(ref));
    final rows = [for (final id in shown) ?s.library.row(id)];
    return PageFrame(
      title: 'Upgrades',
      subtitle:
          'Lossy tracks below your low-bitrate warning (${up.threshold} kbps). Find a better copy, compare them by ear, then choose whether to replace.',
      actions: [
        OutlinedButton(
          onPressed: () => ref.read(viewProvider.notifier).go('settings'),
          child: const Text('Change the warning level'),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Panel(
            title: 'Before you replace anything',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const HintText(bitrateCaveat, icon: Icons.hearing),
                const SizedBox(height: Space.x1),
                const HintText(
                  'Store buttons only open a search on that store\'s own site: nothing is sent until you open one, and nothing is downloaded by DJ Assistant. Buy or download from sources you have the right to use, and follow each store\'s terms.',
                  icon: Icons.storefront_outlined,
                ),
                const SizedBox(height: Space.x1),
                const HintText(
                  'Replacing happens only in Organise Files mode, after a preview. The old file is kept in Removed files and the replacement can be undone.',
                  icon: Icons.verified_user_outlined,
                ),
              ],
            ),
          ),
          gap,
          Wrap(
            spacing: Space.x3,
            runSpacing: Space.x2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                '${plural(ids.length, 'track')} to look at'
                '${kept == 0 ? '' : ' · $kept kept as they are'}',
                style: TextStyle(color: t.muted),
              ),
              if (kept > 0)
                FilterChip(
                  label: const Text('Show kept tracks'),
                  selected: showKept,
                  onSelected: (v) => setState(() => showKept = v),
                ),
            ],
          ),
          const SizedBox(height: Space.x2),
          if (ids.isEmpty)
            EmptyState(
              icon: Icons.high_quality_outlined,
              title: 'Nothing below ${up.threshold} kbps',
              message: 'Lossless files and files with an unknown bitrate are never listed.',
            ),
          for (final r in rows)
            _UpgradeCard(
              key: ValueKey(r.id),
              trackId: r.id,
              title: [
                r.artist,
                r.title ?? r.fileName,
              ].whereType<String>().join(' — '),
              detail:
                  '${r.bitrateKbps ?? '?'} kbps ${r.format ?? ''} · ${fmtDuration(r.durationMs ?? 0)}',
              artist: r.artist ?? '',
              songTitle: r.title ?? r.fileName,
              kept: keptIds.contains(r.id),
            ),
          if (ids.length > shown.length)
            Padding(
              padding: const EdgeInsets.all(Space.x3),
              child: Text(
                'Showing the first ${fmtNumber(shown.length)}. Raise "list rows" in Settings → Limits to see more.',
                style: TextStyle(color: t.faint),
              ),
            ),
        ],
      ),
    );
  }
}

class _UpgradeCard extends ConsumerStatefulWidget {
  const _UpgradeCard({
    super.key,
    required this.trackId,
    required this.title,
    required this.detail,
    required this.artist,
    required this.songTitle,
    this.kept = false,
  });
  final bool kept;
  final int trackId;
  final String title, detail, artist, songTitle;
  @override
  ConsumerState<_UpgradeCard> createState() => _UpgradeCardState();
}

class _UpgradeCardState extends ConsumerState<_UpgradeCard> {
  bool open = false;

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(sessionProvider);
    final t = DjTokens.of(context);
    final up = UpgradeService(s.cat);
    final owned = open ? up.owned(widget.trackId) : const <OwnedAlternative>[];
    return Card(
      margin: const EdgeInsets.only(bottom: Space.x2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            title: Text(
              widget.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(widget.detail),
            trailing: IconButton(
              tooltip: open ? 'Hide options' : 'Show options',
              icon: Icon(open ? Icons.expand_less : Icons.expand_more),
              onPressed: () => setState(() => open = !open),
            ),
            onTap: () => setState(() => open = !open),
          ),
          if (open)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Space.x4,
                0,
                Space.x4,
                Space.x3,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Already in your library',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  if (owned.isEmpty)
                    Text(
                      'No other copy with the same artist and title.',
                      style: TextStyle(color: t.faint),
                    ),
                  for (final o in owned)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        o.facts.path,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        [
                          _quality(o.facts),
                          if (o.reasons.isNotEmpty)
                            'possibly better: ${o.reasons.join(', ')}',
                          if (o.lengthDiffSec != null &&
                              o.lengthDiffSec!.abs() >= 3)
                            'length differs by ${o.lengthDiffSec!.abs().round()} s — maybe another version',
                        ].join(' · '),
                      ),
                      trailing: OutlinedButton(
                        onPressed: () => showCompare(
                          context,
                          ref,
                          widget.trackId,
                          o.facts.path,
                        ),
                        child: const Text('Compare'),
                      ),
                    ),
                  const SizedBox(height: Space.x2),
                  Wrap(
                    spacing: Space.x2,
                    runSpacing: Space.x2,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      FilledButton.tonalIcon(
                        icon: const Icon(Icons.compare_arrows),
                        label: const Text('Compare with a file…'),
                        onPressed: () async {
                          final f = await openFile(
                            acceptedTypeGroups: const [audioTypeGroup],
                            confirmButtonText: 'Compare',
                          );
                          if (f == null || !context.mounted) return;
                          await showCompare(
                            context,
                            ref,
                            widget.trackId,
                            f.path,
                          );
                        },
                      ),
                      MenuAnchor(
                        builder: (c, ctl, _) => OutlinedButton.icon(
                          icon: const Icon(Icons.search),
                          label: const Text('Search a store'),
                          onPressed: ctl.open,
                        ),
                        menuChildren: [
                          for (final l in storeLinks(
                            widget.artist,
                            widget.songTitle,
                          ))
                            MenuItemButton(
                              onPressed: () => openUrl(l['url']!),
                              child: Text(l['store']!),
                            ),
                        ],
                      ),
                      TextButton(
                        onPressed: () => guard(
                          () => widget.kept
                              ? up.unkeep(widget.trackId)
                              : up.keep(widget.trackId),
                          bump: ref,
                        ),
                        child: Text(
                          widget.kept ? 'List it again' : 'Keep as it is',
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

String _quality(AudioFacts f) => [
  if (f.format != null) f.format!,
  if (f.lossless == true)
    'lossless'
  else if (f.bitrateKbps != null)
    '${f.bitrateKbps} kbps',
  if (f.sampleRate != null)
    '${(f.sampleRate! / 1000).toStringAsFixed(f.sampleRate! % 1000 == 0 ? 0 : 1)} kHz',
  if (f.bitDepth != null) '${f.bitDepth}-bit',
].join(' ');

/// Side by side: the current file and a candidate, with the facts and two
/// players at matched loudness (when both are analysed). Replacing goes
/// through Organise Files' preview.
Future<void> showCompare(
  BuildContext context,
  WidgetRef ref,
  int trackId,
  String candidate,
) async {
  final s = ref.read(sessionProvider);
  final up = UpgradeService(s.cat);
  final pair = await guard(
    () => (up.trackFacts(trackId), up.fileFacts(candidate)),
  );
  if (pair == null || !context.mounted) return;
  final (a, b) = pair;
  await showDialog<void>(
    context: context,
    builder: (c) => _CompareDialog(trackId: trackId, a: a, b: b, ref: ref),
  );
}

class _CompareDialog extends StatelessWidget {
  const _CompareDialog({
    required this.trackId,
    required this.a,
    required this.b,
    required this.ref,
  });
  final int trackId;
  final AudioFacts a, b;
  final WidgetRef ref;

  @override
  Widget build(BuildContext context) {
    final t = DjTokens.of(context);
    final gain = UpgradeService.matchGainDb(a, b);
    // Only the louder one is turned down, so neither is boosted into clipping.
    final gainA = gain != null && gain > 0 ? -gain : 0.0;
    final gainB = gain != null && gain < 0 ? gain : 0.0;
    final lengthDiff = a.durationMs == null || b.durationMs == null
        ? null
        : ((b.durationMs! - a.durationMs!) / 1000).abs();
    final rows = <(String, String, String)>[
      ('Format', a.format ?? '?', b.format ?? '?'),
      (
        'Bitrate',
        a.lossless == true ? 'lossless' : '${a.bitrateKbps ?? '?'} kbps',
        b.lossless == true ? 'lossless' : '${b.bitrateKbps ?? '?'} kbps',
      ),
      ('Sample rate', _hz(a.sampleRate), _hz(b.sampleRate)),
      (
        'Bit depth',
        a.bitDepth == null ? '—' : '${a.bitDepth}-bit',
        b.bitDepth == null ? '—' : '${b.bitDepth}-bit',
      ),
      (
        'Length',
        fmtDuration(a.durationMs ?? 0),
        fmtDuration(b.durationMs ?? 0),
      ),
      ('Size', fmtBytes(a.sizeBytes), fmtBytes(b.sizeBytes)),
      ('Loudness', _lufs(a.lufs), _lufs(b.lufs)),
      ('Peak', _db(a.peakDbfs), _db(b.peakDbfs)),
      (
        'Clipping',
        a.clippedRuns == null ? 'not analysed' : '${a.clippedRuns} runs',
        b.clippedRuns == null ? 'not analysed' : '${b.clippedRuns} runs',
      ),
    ];
    final width = (MediaQuery.sizeOf(context).width - 64)
        .clamp(320, 900)
        .toDouble();
    return AlertDialog(
      title: const Text('Compare by ear'),
      content: SizedBox(
        width: width,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const HintText(bitrateCaveat, icon: Icons.hearing),
              const SizedBox(height: Space.x3),
              Table(
                columnWidths: const {
                  0: IntrinsicColumnWidth(),
                  1: FlexColumnWidth(),
                  2: FlexColumnWidth(),
                },
                defaultVerticalAlignment: TableCellVerticalAlignment.middle,
                children: [
                  TableRow(
                    children: [
                      const SizedBox(),
                      _head('Current', a.path),
                      _head('Candidate', b.path),
                    ],
                  ),
                  for (final (k, x, y) in rows)
                    TableRow(
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(right: Space.x3),
                          child: Text(k, style: TextStyle(color: t.faint)),
                        ),
                        Text(x),
                        Text(
                          y,
                          style: x == y
                              ? null
                              : const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                ],
              ),
              const SizedBox(height: Space.x3),
              if (lengthDiff != null && lengthDiff >= 3)
                HintText(
                  'The lengths differ by ${lengthDiff.round()} seconds: this may be a different version or edit (Serato cues set on the current file would no longer line up).',
                  icon: Icons.warning_amber,
                ),
              Text(
                gain == null
                    ? 'Loudness not matched: analyse both files first (the candidate must be in your library to be analysed). The louder one will tend to sound "better".'
                    : 'Played at matched loudness (the louder file is turned down by ${gain.abs().toStringAsFixed(1)} dB), so you hear the quality, not the volume.',
                style: TextStyle(color: t.muted, fontSize: DjType.small),
              ),
              const SizedBox(height: Space.x2),
              const Text('Current'),
              PreviewPlayer(
                path: a.path,
                durationMs: a.durationMs,
                gainDb: gainA,
                label: 'current file',
              ),
              const Text('Candidate'),
              PreviewPlayer(
                path: b.path,
                durationMs: b.durationMs,
                gainDb: gainB,
                label: 'candidate file',
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        FilledButton(
          onPressed: () async {
            final done = await replaceWithBetterFile(
              context,
              ref,
              trackId,
              source: b.path,
            );
            if (done && context.mounted) Navigator.pop(context);
          },
          child: const Text('Replace current with candidate…'),
        ),
      ],
    );
  }

  Widget _head(String label, String path) => Padding(
    padding: const EdgeInsets.only(bottom: Space.x2),
    child: Tooltip(
      message: path,
      child: Text(
        '$label\n${path.split(RegExp(r'[/\\]')).last}',
        style: const TextStyle(fontWeight: FontWeight.w700),
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
    ),
  );
}

String _hz(int? v) => v == null ? '—' : '${(v / 1000).toStringAsFixed(1)} kHz';
String _lufs(double? v) =>
    v == null ? 'not analysed' : '${v.toStringAsFixed(1)} LUFS';
String _db(double? v) =>
    v == null ? 'not analysed' : '${v.toStringAsFixed(1)} dBFS';
