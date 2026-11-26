import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/analyse_job.dart';
import 'format.dart';
import 'state.dart';
import 'theme.dart';
import 'widgets.dart';

/// Tracks sent from the Library to Analyse (label, ids), or null.
class AnalyseTargetNotifier extends Notifier<(String, List<int>)?> {
  @override
  (String, List<int>)? build() => null;
  void set((String, List<int>)? v) => state = v;
}

final analyseTargetProvider =
    NotifierProvider<AnalyseTargetNotifier, (String, List<int>)?>(
      AnalyseTargetNotifier.new,
    );

/// Runs Analyse on [ids] straight away (from the Library) and opens the page.
Future<void> startOnlineAnalysis(WidgetRef ref, List<int> ids) async {
  if (ids.isEmpty) return;
  final s = ref.read(sessionProvider);
  ref.read(analyseTargetProvider.notifier).set((
    '${plural(ids.length, 'selected track')} from the Library',
    ids,
  ));
  await guard(
    () => s.runAnalyse(scope: 'ids', ids: ids),
    done: 'Analysing ${plural(ids.length, 'track')}…',
  );
  ref.read(viewProvider.notifier).go('analyse');
}

/// One online analyser as the page lists it.
class _Analyser {
  const _Analyser(this.id, this.name, this.gives, {this.key});
  final String id, name, gives;

  /// The credential it needs ("spotify", "youtube"), if any.
  final String? key;
}

const _analysers = [
  _Analyser(
    'musicbrainz',
    'MusicBrainz',
    'Original year, album, label and genre tags. Free.',
  ),
  _Analyser(
    'catalogs',
    'Deezer + Apple Music',
    'Genre, year, album and label. Free, no key. Two votes.',
  ),
  _Analyser(
    'spotify',
    'Spotify',
    'Release year, album, artist genres. Needs a free developer key.',
    key: 'spotify',
  ),
  _Analyser(
    'discogs',
    'Discogs',
    'Style, original year, album and label. Needs a free personal token.',
    key: 'discogs',
  ),
  _Analyser(
    'youtube',
    'YouTube Music',
    'Release year, album, label. Free key, about 100 tracks a day.',
    key: 'youtube',
  ),
];

/// Analysis → Analyse: one button for BPM and key from Serato, energy (on
/// every CPU core), and the online analysers on many tracks at once with the
/// majority deciding the tags.
class AnalyseScreen extends ConsumerStatefulWidget {
  const AnalyseScreen({super.key});
  @override
  ConsumerState<AnalyseScreen> createState() => _AnalyseScreenState();
}

class _AnalyseScreenState extends ConsumerState<AnalyseScreen> {
  String scope = 'new';
  Timer? _tick;
  String? _was;

  @override
  void initState() {
    super.initState();
    if (ref.read(analyseTargetProvider) != null) scope = 'ids';
    _tick = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted) return;
      final st = ref.read(sessionProvider).jobs.status('online').state;
      if (st == 'running' || st == 'paused' || st != _was) {
        if (_was != null && st != _was) {
          ref.read(versionProvider.notifier).bump();
        }
        _was = st;
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  void _run() {
    final s = ref.read(sessionProvider);
    final target = ref.read(analyseTargetProvider);
    guard(
      () => s.runAnalyse(scope: scope, ids: scope == 'ids' ? target?.$2 : null),
      done: 'Analysing…',
    );
    setState(() {});
  }

  Future<void> _setKey(_Analyser a) async {
    final s = ref.read(sessionProvider);
    final v = await askText(
      context,
      title: '${a.name} key',
      label: switch (a.key) {
        'spotify' => 'Client ID:Client secret',
        'discogs' => 'Discogs personal access token',
        _ => 'YouTube Data API key',
      },
      ok: 'Save',
    );
    if (v == null) return;
    await guard(
      () {
        s.settings.setSecret(a.key!, v);
        s.settings.setService(a.id, true);
      },
      done: '${a.name} is on.',
      bump: ref,
    );
  }

  Future<void> _pickOneTagger() async {
    final s = ref.read(sessionProvider);
    final f = await openFile(confirmButtonText: 'Use this program');
    if (f == null) return;
    await guard(
      () => s.taggers.setPath('onetagger', f.path),
      done: 'OneTagger found.',
      bump: ref,
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(sessionProvider);
    ref.watch(versionProvider);
    final t = DjTokens.of(context);
    final text = Theme.of(context).textTheme;
    final job = s.jobs.status('online');
    final live = job.state == 'running' || job.state == 'paused';
    final report = lastAnalyseReport(s.cat);
    final target = ref.watch(analyseTargetProvider);
    final services = {for (final x in s.settings.services()) '${x['id']}': x};
    final serato = s.seratoDirs;
    final otPath = s.taggers.path('onetagger');
    final otOn = s.taggers.enabled('onetagger');
    final voters =
        _analysers.where((a) {
          final x = services[a.id];
          return x?['enabled'] == true &&
              (a.key == null || x?['has_key'] == true);
        }).length +
        (services['catalogs']?['enabled'] == true ? 1 : 0) +
        (otOn && otPath != null ? 1 : 0);

    final controls = Panel(
      child: Wrap(
        spacing: Space.x3,
        runSpacing: Space.x3,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: 340,
            child: DropdownButtonFormField<String>(
              isExpanded: true,
              initialValue: scope,
              decoration: const InputDecoration(labelText: 'Work on'),
              items: [
                DropdownMenuItem(
                  value: 'new',
                  child: Text(analyseScopes['new']!),
                ),
                DropdownMenuItem(
                  value: 'all',
                  child: Text(analyseScopes['all']!),
                ),
                if (target != null)
                  DropdownMenuItem(value: 'ids', child: Text(target.$1)),
              ],
              onChanged: live
                  ? null
                  : (v) => setState(() => scope = v ?? 'new'),
            ),
          ),
          FilledButton.icon(
            onPressed: live ? null : _run,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(
                horizontal: Space.x5,
                vertical: Space.x4,
              ),
            ),
            icon: const Icon(Icons.travel_explore_outlined),
            label: const Text('Analyse'),
          ),
          if (live)
            OutlinedButton.icon(
              onPressed: () => s.jobs.cancel('online'),
              icon: const Icon(Icons.stop),
              label: const Text('Stop'),
            ),
        ],
      ),
    );

    final status = live
        ? Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(job.message ?? 'Working…', style: text.bodyMedium),
                const SizedBox(height: Space.x2),
                LinearProgressIndicator(
                  value: job.total > 0 ? job.done / job.total : null,
                ),
                if (job.total > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: Space.x1),
                    child: Text(
                      '${job.done} of ${job.total}',
                      style: TextStyle(color: t.faint, fontSize: DjType.small),
                    ),
                  ),
              ],
            ),
          )
        : report == null
        ? null
        : Panel(
            child: Row(
              children: [
                Icon(Icons.flag_outlined, color: t.accent),
                const SizedBox(width: Space.x3),
                Expanded(
                  child: Text('${report['summary']}', style: text.bodyMedium),
                ),
                Text(
                  fmtDateTime(report['finished_at'] as int?),
                  style: TextStyle(color: t.faint, fontSize: DjType.small),
                ),
              ],
            ),
          );

    Widget row({
      required IconData icon,
      required String name,
      required String gives,
      required bool on,
      ValueChanged<bool>? onChanged,
      Widget? extra,
    }) => ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: on ? t.accent : t.faint),
      title: Text(name),
      subtitle: Text(gives),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ?extra,
          Switch(value: on, onChanged: onChanged),
        ],
      ),
    );

    final analysers = Panel(
      title: 'Analysers',
      subtitle:
          'Every analyser that is on is asked about each track at the same '
          'time. For genre, year, album and label the answer most of them '
          'agree on wins. A tie changes nothing, and replacing a value you '
          'already have needs at least two analysers agreeing.',
      child: Column(
        children: [
          row(
            icon: Icons.album_outlined,
            name: 'Serato DJ (BPM and key)',
            gives: serato.isEmpty
                ? 'No _Serato_ folder found. BPM and key tags in the files are used.'
                : "Serato's own analysis from ${serato.join(', ')}",
            on: true,
          ),
          row(
            icon: Icons.bolt_outlined,
            name: 'Energy (this computer)',
            gives: '1–10 energy from the audio, for crates and sorting.',
            on: s.settings.all()['energy_analysis'] == true,
            onChanged: live
                ? null
                : (v) => guard(
                    () => s.settings.set('energy_analysis', v),
                    bump: ref,
                  ),
          ),
          const Divider(),
          for (final a in _analysers)
            row(
              icon: Icons.public,
              name: a.name,
              gives: a.gives,
              on: services[a.id]?['enabled'] == true,
              extra: a.key == null
                  ? null
                  : TextButton(
                      onPressed: () => _setKey(a),
                      child: Text(
                        services[a.id]?['has_key'] == true
                            ? 'Change key'
                            : 'Add key',
                      ),
                    ),
              onChanged: live
                  ? null
                  : (v) {
                      if (v &&
                          a.key != null &&
                          services[a.id]?['has_key'] != true) {
                        _setKey(a);
                        return;
                      }
                      guard(() => s.settings.setService(a.id, v), bump: ref);
                    },
            ),
          row(
            icon: Icons.sell_outlined,
            name: 'OneTagger',
            gives: otPath == null
                ? 'Beatport, Traxsource, Juno and more. Not found: install it, '
                      'or choose onetagger-cli.'
                : 'Beatport, Traxsource, Juno and more (${s.taggers.oneTaggerPlatforms}). '
                      'Works on temporary copies that are deleted afterwards.',
            on: otOn && otPath != null,
            extra: TextButton(
              onPressed: _pickOneTagger,
              child: Text(otPath == null ? 'Find…' : 'Change…'),
            ),
            onChanged: live || otPath == null
                ? null
                : (v) => guard(
                    () => s.taggers.setEnabled('onetagger', v),
                    bump: ref,
                  ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: Space.x2),
            child: HintText(
              voters == 0
                  ? 'Switch on at least one online analyser to fix genre, year and tags.'
                  : '$voters vote(s) per track. Changes are written straight into your '
                        'music files and listed under Changes, where Undo puts the old value back.',
            ),
          ),
        ],
      ),
    );

    return PageFrame(
      title: 'Analyse',
      subtitle:
          'BPM and key from Serato; genre, year, album and label from the '
          'online analysers, many tracks at once. The majority wins and is '
          'written into your files.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          controls,
          if (status != null) ...[const SizedBox(height: Space.x3), status],
          const SizedBox(height: Space.x3),
          analysers,
        ],
      ),
    );
  }
}
