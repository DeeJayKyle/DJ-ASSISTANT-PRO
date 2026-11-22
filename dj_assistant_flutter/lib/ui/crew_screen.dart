import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/crew.dart';
import '../core/taggers.dart';
import 'format.dart';
import 'hubs.dart';
import 'state.dart';
import 'theme.dart';
import 'widgets.dart';

/// Each agent's look: icon and colour (dark, light).
const _agentLook = <String, (IconData, Color, Color)>{
  'scout': (Icons.travel_explore, Color(0xFF38BDF8), Color(0xFF0369A1)),
  'listener': (Icons.hearing, Color(0xFFA78BFA), Color(0xFF6D28D9)),
  'detective': (Icons.manage_search, Color(0xFFFBBF24), Color(0xFFB45309)),
  'librarian': (
    Icons.local_library_outlined,
    Color(0xFF2DD4BF),
    Color(0xFF0F766E),
  ),
  'taggers': (
    Icons.auto_awesome_motion_outlined,
    Color(0xFFF472B6),
    Color(0xFFBE185D),
  ),
  'judge': (Icons.gavel, Color(0xFFFB923C), Color(0xFFC2410C)),
  'clerk': (
    Icons.assignment_turned_in_outlined,
    Color(0xFF4ADE80),
    Color(0xFF15803D),
  ),
};

Color agentColor(BuildContext c, String id) {
  final x = _agentLook[id]!;
  return Theme.of(c).brightness == Brightness.light ? x.$3 : x.$2;
}

/// Tracks sent from the Library to the crew (label, ids), or null.
final crewTargetProvider =
    NotifierProvider<OrganiseTargetNotifier, (String, List<int>)?>(
      OrganiseTargetNotifier.new,
    );

/// Analysis → Analyse: one button runs every analyser as a crew of agents.
class CrewScreen extends ConsumerStatefulWidget {
  const CrewScreen({super.key});
  @override
  ConsumerState<CrewScreen> createState() => _CrewScreenState();
}

class _CrewScreenState extends ConsumerState<CrewScreen> {
  String scope = 'new';
  Timer? _tick;
  String? _was;

  @override
  void initState() {
    super.initState();
    if (ref.read(crewTargetProvider) != null) scope = 'ids';
    // follow the crew while it works
    _tick = Timer.periodic(const Duration(milliseconds: 400), (_) {
      if (!mounted) return;
      final st = ref.read(sessionProvider).jobs.status('crew').state;
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
    final target = ref.read(crewTargetProvider);
    guard(
      () => s.runCrew(scope: scope, ids: scope == 'ids' ? target?.$2 : null),
      done: 'The crew is on it.',
    );
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(sessionProvider);
    ref.watch(versionProvider);
    final t = DjTokens.of(context);
    final text = Theme.of(context).textTheme;
    final nav = ref.read(viewProvider.notifier);
    final job = s.jobs.status('crew');
    final live = job.state == 'running' || job.state == 'paused';
    final speaking = live ? parseCrewMessage(job.message) : null;
    final report = lastCrewReport(s.cat);
    final reports = {
      for (final a in (report?['agents'] as List?) ?? const [])
        '${(a as Map)['id']}': Map<String, Object?>.from(a),
    };
    final off = crewOff(s.cat);
    final target = ref.watch(crewTargetProvider);
    final pending = ref.watch(pendingSuggestionsProvider);
    final taggersFound = [
      for (final d in taggerDefs)
        if (d.mode == TaggerMode.automatic && s.taggers.path(d.id) != null)
          d.name,
    ];
    final onlineOn = ref.watch(onlineOnProvider);

    String statusOf(String id) {
      if (live) {
        if (speaking?.$1 == id) return 'working';
        final order = crewAgents.map((a) => a.id).toList();
        final now = speaking == null ? -1 : order.indexOf(speaking.$1);
        return order.indexOf(id) < now ? 'passed' : 'waiting';
      }
      return '${reports[id]?['status'] ?? 'ready'}';
    }

    // What each agent will work with, so the DJ sees why one would skip.
    String? brief(String id) => switch (id) {
      'librarian' =>
        onlineOn.isEmpty
            ? 'No online services on (Settings → Online services).'
            : 'Uses: ${onlineOn.join(', ')}',
      'taggers' =>
        taggersFound.isEmpty
            ? 'OneTagger / beets not found (Analysis → Taggers).'
            : 'Uses: ${taggersFound.join(', ')}',
      _ => null,
    };

    final controls = Panel(
      child: Wrap(
        spacing: Space.x3,
        runSpacing: Space.x3,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: 380,
            child: DropdownButtonFormField<String>(
              isExpanded: true,
              initialValue: scope,
              decoration: const InputDecoration(labelText: 'Work on'),
              items: [
                DropdownMenuItem(value: 'new', child: Text(crewScopes['new']!)),
                DropdownMenuItem(value: 'all', child: Text(crewScopes['all']!)),
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
            icon: const Icon(Icons.groups_2_outlined),
            label: const Text('Run the crew'),
          ),
          if (live)
            OutlinedButton.icon(
              onPressed: () => s.jobs.cancel('crew'),
              icon: const Icon(Icons.stop),
              label: const Text('Stop'),
            ),
          DjLink(
            label: pending == 0
                ? 'Suggestions'
                : '$pending suggestion(s) to review',
            icon: Icons.auto_fix_high_outlined,
            color: hubs[1].color(context),
            hint: tabOf('suggestions')!.hint,
            onTap: () => nav.go('suggestions'),
          ),
        ],
      ),
    );

    final cards = [
      for (final a in crewAgents)
        _AgentCard(
          agent: a,
          status: statusOf(a.id),
          speaking: speaking?.$1 == a.id ? speaking!.$2 : null,
          done: live && speaking?.$1 == a.id ? job.done : 0,
          total: live && speaking?.$1 == a.id ? job.total : 0,
          last: live ? null : reports[a.id]?['summary'] as String?,
          brief: brief(a.id),
          on: !off.contains(a.id),
          onToggle: a.id == 'scout' || live
              ? null
              : (v) {
                  final next = {...off};
                  v ? next.remove(a.id) : next.add(a.id);
                  setCrewOff(s.cat, next);
                  ref.read(versionProvider.notifier).bump();
                },
          link: switch (a.id) {
            'listener' => ('Library map', 'map'),
            'detective' || 'judge' || 'clerk' => ('Suggestions', 'suggestions'),
            'librarian' => ('Settings', 'settings'),
            'taggers' => ('Taggers', 'taggers'),
            _ => ('Health', 'health'),
          },
        ),
    ];

    return PageFrame(
      title: 'Analyse',
      subtitle:
          'One button runs every analyser as a crew: each agent has a role and '
          'hands its work to the next. Your music files are never changed.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          controls,
          if (report != null && !live) ...[
            const SizedBox(height: Space.x3),
            Panel(
              child: Row(
                children: [
                  Icon(
                    Icons.flag_outlined,
                    color: agentColor(context, 'clerk'),
                  ),
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
            ),
          ],
          const SizedBox(height: Space.x3),
          _CrewGrid(cards: cards),
        ],
      ),
    );
  }
}

/// Agents in their working order: a bento of 3 / 2 / 1 columns, the first and
/// the Judge wide.
class _CrewGrid extends StatelessWidget {
  const _CrewGrid({required this.cards});
  final List<_AgentCard> cards;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final cols = box.maxWidth >= 1000 ? 3 : (box.maxWidth >= 600 ? 2 : 1);
        final gap = Space.x3;
        final unit = (box.maxWidth - gap * (cols - 1)) / cols;
        double width(String id) {
          final span = switch (id) {
            'scout' || 'judge' => cols >= 3 ? 2 : cols,
            _ => 1,
          };
          return unit * span + gap * (span - 1);
        }

        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final c in cards) SizedBox(width: width(c.agent.id), child: c),
          ],
        );
      },
    );
  }
}

/// One agent: who it is, what it does, its status and its last word.
class _AgentCard extends ConsumerWidget {
  const _AgentCard({
    required this.agent,
    required this.status,
    required this.speaking,
    required this.done,
    required this.total,
    required this.last,
    required this.brief,
    required this.on,
    required this.onToggle,
    required this.link,
  });
  final CrewAgent agent;
  final String status;
  final String? speaking, last, brief;
  final int done, total;
  final bool on;
  final ValueChanged<bool>? onToggle;
  final (String, String) link;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = DjTokens.of(context);
    final text = Theme.of(context).textTheme;
    final c = agentColor(context, agent.id);
    final working = status == 'working';
    final step = crewAgents.indexOf(agent) + 1;
    final (label, color) = switch (status) {
      'working' => ('Working', c),
      'done' => ('Done', t.ok),
      'passed' => ('Done', t.ok),
      'skipped' => ('Skipped', t.faint),
      'failed' => ('Problem', t.danger),
      'waiting' => ('Waiting', t.faint),
      _ => (on ? 'Ready' : 'Off', t.faint),
    };
    return Tooltip(
      message: '${agent.detail}\nStep $step of ${crewAgents.length}',
      waitDuration: const Duration(milliseconds: 500),
      child: AnimatedContainer(
        duration: Motion.base(context),
        padding: const EdgeInsets.all(Space.x4),
        decoration: BoxDecoration(
          borderRadius: Radii.large,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color.alphaBlend(
                t.tint(c, working ? 0.30 : (on ? 0.18 : 0.06)),
                t.panel,
              ),
              Color.alphaBlend(t.tint(c, 0.04), t.panel),
            ],
          ),
          border: Border.all(
            color: t.tint(c, working ? 0.95 : (on ? 0.40 : 0.15)),
            width: working ? 2 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(Space.x2),
                  decoration: BoxDecoration(
                    color: t.tint(c, 0.22),
                    borderRadius: Radii.medium,
                  ),
                  child: Icon(agent.iconData, color: c, size: IconSizes.lg),
                ),
                const SizedBox(width: Space.x3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '$step · ${agent.name}',
                        style: text.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(agent.role, style: TextStyle(color: c)),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: Space.x2,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: t.tint(color, 0.16),
                    borderRadius: Radii.small,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (working)
                        Padding(
                          padding: const EdgeInsets.only(right: Space.x1),
                          child: SizedBox(
                            width: 10,
                            height: 10,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: c,
                            ),
                          ),
                        ),
                      Text(
                        label,
                        style: TextStyle(
                          color: color,
                          fontSize: DjType.small,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                if (agent.id != 'scout')
                  Tooltip(
                    message: on
                        ? 'Switch ${agent.name} off for the next runs'
                        : 'Switch ${agent.name} on',
                    child: Switch(value: on, onChanged: onToggle),
                  ),
              ],
            ),
            const SizedBox(height: Space.x2),
            Text(agent.detail, style: TextStyle(color: t.muted)),
            if (brief != null) ...[
              const SizedBox(height: Space.x1),
              Text(
                brief!,
                style: TextStyle(color: t.faint, fontSize: DjType.small),
              ),
            ],
            if (working) ...[
              const SizedBox(height: Space.x2),
              ProgressLine(
                label: speaking ?? 'Working…',
                done: done,
                total: total,
              ),
            ] else if (last != null && last!.isNotEmpty) ...[
              const SizedBox(height: Space.x2),
              Text(
                last!,
                style: TextStyle(
                  color: status == 'failed' ? t.danger : t.text,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
            const SizedBox(height: Space.x2),
            DjLink(
              label: link.$1,
              color: c,
              hint: tabOf(link.$2)?.hint,
              onTap: () => ref.read(viewProvider.notifier).go(link.$2),
            ),
          ],
        ),
      ),
    );
  }
}

extension on CrewAgent {
  IconData get iconData => _agentLook[id]!.$1;
}
