import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/accounts.dart';
import '../core/crates.dart';
import '../core/jobs.dart';
import '../online/http_online.dart' show appVersion;
import 'assistant_panel.dart';
import 'crates_screen.dart';
import 'format.dart';
import 'screens.dart';
import 'state.dart';
import 'theme.dart';
import 'widgets.dart';

class _Nav {
  const _Nav(this.id, this.label, this.icon);
  final String id, label;
  final IconData icon;
}

const _main = [
  _Nav('quick', 'Quick Prep', Icons.bolt_outlined),
  _Nav('library', 'Library', Icons.library_music_outlined),
  _Nav('crates', 'Virtual Crates', Icons.inventory_2_outlined),
  _Nav('duplicates', 'Duplicate Review', Icons.copy_all_outlined),
  _Nav('activity', 'Scan Activity', Icons.refresh),
  _Nav('health', 'Library Health', Icons.favorite_outline),
  _Nav('organize', 'Organise Files', Icons.build_outlined),
];
const _create = [
  _Nav('studio:stems', 'Stems', Icons.layers_outlined),
  _Nav('studio:remix', 'Remix', Icons.shuffle),
  _Nav('studio:dj', 'DJ Decks', Icons.headphones_outlined),
  _Nav('studio:synth', 'Synth Lab', Icons.graphic_eq),
  _Nav('studio:drums', 'Drum Lab', Icons.album_outlined),
];
const _prepare = [
  _Nav('set-studio', 'Set Studio', Icons.queue_music_outlined),
  _Nav('discovery', 'Discovery', Icons.explore_outlined),
  _Nav('suggestions', 'Suggestions', Icons.auto_fix_high_outlined),
  _Nav('gig', 'Gig Mode', Icons.sensors),
  _Nav('gig-pack', 'Gig Pack', Icons.usb_outlined),
];

class Shell extends ConsumerStatefulWidget {
  const Shell({super.key});
  @override
  ConsumerState<Shell> createState() => _ShellState();
}

class _ShellState extends ConsumerState<Shell> {
  Timer? _poll;
  final _prev = <String, String>{};
  String _prevScan = 'idle';
  int _lastDone = 0;

  @override
  void initState() {
    super.initState();
    _poll = Timer.periodic(const Duration(milliseconds: 800), (_) => _watch());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  /// Scan and job progress: toasts when they finish, catalogue refresh.
  void _watch() {
    if (!mounted) return;
    final s = ref.read(sessionProvider);
    bool live(String st) => st == 'running' || st == 'paused';
    var changed = false;
    final sc = s.lastScan;
    if (sc != null) {
      if (live(_prevScan) && !live(sc.state)) {
        changed = true;
        toast(
          sc.state == 'completed'
              ? 'Scan complete: ${sc.added} new, ${sc.updated} updated, ${sc.errors} problem${sc.errors == 1 ? '' : 's'}.'
              : 'Scan ${sc.state}.',
          error: sc.state == 'failed',
        );
      }
      final done = sc.filesProcessed + sc.unchanged;
      if (sc.state == 'running' && done - _lastDone >= 500) {
        _lastDone = done;
        changed = true;
      }
      _prevScan = sc.state;
    }
    for (final j in s.jobs.all()) {
      final was = _prev[j.kind];
      if (was != null && live(was) && !live(j.state)) {
        changed = true;
        final name = j.kind[0].toUpperCase() + j.kind.substring(1);
        toast(
          j.state == 'failed'
              ? '${j.kind} failed: ${j.message ?? ''}'
              : '$name ${j.state}${j.errors > 0 ? ' (${j.errors} could not be processed)' : ''}.',
          error: j.state == 'failed',
        );
      }
      _prev[j.kind] = j.state;
    }
    if (changed) ref.read(versionProvider.notifier).bump();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final view = ref.watch(viewProvider);
    final chat = ref.watch(chatModeProvider);
    final body = screenFor(view);
    final studio = view.id.startsWith('studio:');
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyJ, control: true): () => ref
            .read(chatModeProvider.notifier)
            .set(chat == 'hidden' ? 'open' : 'hidden'),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: LayoutBuilder(
            builder: (context, box) {
              final w = box.maxWidth;
              final rail = w < 1240;
              final chatW = w < 1280 ? 320.0 : (w < 1600 ? 360.0 : 400.0);
              return Column(
                children: [
                  const _TitleBar(),
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (chat != 'full') _Sidebar(rail: rail),
                        if (chat != 'full') const VerticalDivider(width: 1),
                        if (chat != 'full')
                          Expanded(
                            child: Stack(
                              children: [
                                // Studio stays mounted once opened, so decks keep playing.
                                Offstage(
                                  offstage: !studio,
                                  child: const StudioHost(),
                                ),
                                if (!studio) Positioned.fill(child: body),
                              ],
                            ),
                          ),
                        if (chat == 'open')
                          SizedBox(width: chatW, child: const AssistantPanel()),
                        if (chat == 'full')
                          const Expanded(child: AssistantPanel()),
                      ],
                    ),
                  ),
                  const _StatusBar(),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _TitleBar extends ConsumerWidget {
  const _TitleBar();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = DjTokens.of(context);
    final accounts = ref.watch(accountsProvider);
    ref.watch(sessionProvider);
    final cur = accounts.accounts
        .where((a) => a.id == accounts.currentId)
        .firstOrNull;
    return Container(
      height: 46,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: t.line)),
      ),
      child: Row(
        children: [
          Icon(Icons.graphic_eq, color: t.accent, size: 20),
          const SizedBox(width: 8),
          const Text(
            'DJ Assistant',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: DjType.title,
            ),
          ),
          const SizedBox(width: 16),
          MenuAnchor(
            builder: (c, ctl, _) => TextButton.icon(
              onPressed: () => ctl.isOpen ? ctl.close() : ctl.open(),
              icon: CircleAvatar(
                radius: 9,
                backgroundColor: Color(
                  int.tryParse(
                        (cur?.color ?? '#3DDBB0').replaceFirst('#', 'FF'),
                        radix: 16,
                      ) ??
                      0xFF3DDBB0,
                ),
              ),
              label: Text(cur?.name ?? 'Account'),
            ),
            menuChildren: [
              for (final a in accounts.accounts)
                MenuItemButton(
                  leadingIcon: Icon(
                    a.id == accounts.currentId
                        ? Icons.check
                        : Icons.person_outline,
                    size: 18,
                  ),
                  onPressed: a.id == accounts.currentId
                      ? null
                      : () => guard(() {
                          ref.read(sessionProvider.notifier).switchTo(a.id);
                          ref.read(viewProvider.notifier).go('library');
                        }, done: 'Opened ${a.name}.'),
                  child: Text(a.name),
                ),
              const Divider(),
              MenuItemButton(
                leadingIcon: const Icon(Icons.person_add_alt, size: 18),
                onPressed: () async {
                  final n = await askText(
                    context,
                    title: 'New account',
                    label: 'Name (e.g. Club nights, Weddings)',
                    ok: 'Create',
                  );
                  if (n == null) return;
                  await guard(
                    () {
                      final acct = accounts.create(n);
                      ref.read(sessionProvider.notifier).switchTo(acct.id);
                    },
                    done:
                        'Created $n. It has its own library, crates and settings.',
                  );
                },
                child: const Text('New account…'),
              ),
              MenuItemButton(
                leadingIcon: const Icon(
                  Icons.manage_accounts_outlined,
                  size: 18,
                ),
                onPressed: () => _manage(context, ref, accounts),
                child: const Text('Manage accounts…'),
              ),
            ],
          ),
          const Spacer(),
          if (ref.watch(chatModeProvider) == 'hidden')
            TextButton.icon(
              onPressed: () => ref.read(chatModeProvider.notifier).set('open'),
              icon: const Icon(Icons.auto_awesome, size: 16),
              label: const Text('Assistant'),
            ),
        ],
      ),
    );
  }

  void _manage(BuildContext context, WidgetRef ref, AccountsService accounts) =>
      showDialog<void>(
        context: context,
        builder: (c) => StatefulBuilder(
          builder: (c, set) => AlertDialog(
            title: const Text('Accounts'),
            content: SizedBox(
              width: 460,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const HintText(
                    'Each account has its own library folders, catalogue, crates, sets and settings. Music files are shared on disk and never copied.',
                  ),
                  for (final a in accounts.accounts)
                    ListTile(
                      title: Text(a.name),
                      subtitle: a.id == accounts.currentId
                          ? const Text('Open now')
                          : null,
                      trailing: Wrap(
                        children: [
                          IconButton(
                            tooltip: 'Rename',
                            icon: const Icon(Icons.edit_outlined, size: 18),
                            onPressed: () async {
                              final n = await askText(
                                c,
                                title: 'Rename account',
                                initial: a.name,
                              );
                              if (n != null) {
                                await guard(() => accounts.rename(a.id, n));
                              }
                              set(() {});
                            },
                          ),
                          IconButton(
                            tooltip: 'Remove',
                            icon: const Icon(Icons.delete_outline, size: 18),
                            onPressed: () async {
                              final ok = await confirm(
                                c,
                                title: 'Remove “${a.name}”?',
                                message: "This deletes the account's catalogue (crates, sets, ratings and notes). Your music files are not touched.",
                                ok: 'Remove',
                                danger: true,
                              );
                              if (!ok) return;
                              final wasOpen = a.id == accounts.currentId;
                              await guard(() {
                                if (wasOpen) {
                                  final other = accounts.accounts.firstWhere(
                                    (x) => x.id != a.id,
                                  );
                                  ref
                                      .read(sessionProvider.notifier)
                                      .switchTo(other.id);
                                }
                                accounts.delete(a.id);
                              });
                              set(() {});
                            },
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c),
                child: const Text('Close'),
              ),
            ],
          ),
        ),
      );
}

class _Sidebar extends ConsumerStatefulWidget {
  const _Sidebar({this.rail = false});

  /// Icons only (compact windows): crates and sources are one click away on
  /// the Virtual Crates and Scan Activity pages.
  final bool rail;
  @override
  ConsumerState<_Sidebar> createState() => _SidebarState();
}

class _SidebarState extends ConsumerState<_Sidebar> {
  final open = <int>{};
  bool sources = true;

  @override
  Widget build(BuildContext context) {
    final t = DjTokens.of(context);
    final view = ref.watch(viewProvider);
    final stats = ref.watch(statsProvider);
    final crates = ref.watch(cratesProvider);
    final roots = ref.watch(rootsProvider);
    final pending = ref.watch(pendingSuggestionsProvider);
    final docs = ref.watch(settingsProvider)['docs_enabled'] == true;
    final problems =
        (stats['errors'] ?? 0) +
        (stats['missing'] ?? 0) +
        (stats['low_bitrate'] ?? 0);
    Widget item(_Nav n, {String? count, bool warn = false}) => _NavItem(
      nav: n,
      selected: view.id == n.id || (n.id == 'library' && view.id == 'library'),
      rail: widget.rail,
      count: count,
      warn: warn,
      onTap: () => ref.read(viewProvider.notifier).go(n.id),
    );

    Widget section(String label, {Widget? trailing}) => widget.rail
        ? const Padding(
            padding: EdgeInsets.symmetric(
              horizontal: Space.x4,
              vertical: Space.x2,
            ),
            child: Divider(),
          )
        : Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 10, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    label.toUpperCase(),
                    style: TextStyle(
                      fontSize: DjType.caption,
                      letterSpacing: 1.2,
                      color: t.faint,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                ?trailing,
              ],
            ),
          );

    List<Widget> tree(int? parent, int depth) => [
      for (final c in crates.where((c) => c.parentId == parent)) ...[
        ListTile(
          dense: true,
          visualDensity: VisualDensity.compact,
          contentPadding: EdgeInsets.only(left: 18.0 + depth * 14, right: 10),
          selected: view.id == 'crate' && view.crateId == c.id,
          selectedColor: t.accent,
          leading: crates.any((k) => k.parentId == c.id)
              ? InkWell(
                  onTap: () => setState(
                    () => open.contains(c.id)
                        ? open.remove(c.id)
                        : open.add(c.id),
                  ),
                  child: Icon(
                    open.contains(c.id)
                        ? Icons.expand_more
                        : Icons.chevron_right,
                    size: 18,
                  ),
                )
              : (c.color != null
                    ? ColorDot(c.color)
                    : const Icon(Icons.inventory_2_outlined, size: 16)),
          minLeadingWidth: 18,
          title: Text(c.name, overflow: TextOverflow.ellipsis),
          subtitle: c.smart
              ? const Text('smart', style: TextStyle(fontSize: DjType.caption))
              : null,
          trailing: Text(
            c.trackCount == 0 ? '' : '${c.trackCount}',
            style: TextStyle(fontSize: DjType.caption, color: t.faint),
          ),
          onTap: () =>
              ref.read(viewProvider.notifier).go('crate', crateId: c.id),
        ),
        if (open.contains(c.id)) ...tree(c.id, depth + 1),
      ],
    ];

    if (widget.rail) {
      return SizedBox(
        width: 64,
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: Space.x2),
          children: [
            for (final n in _main)
              item(
                n,
                count: n.id == 'health' && problems > 0 ? '$problems' : null,
                warn: n.id == 'health',
              ),
            section(''),
            for (final n in _create) item(n),
            section(''),
            for (final n in _prepare)
              item(
                n,
                count: n.id == 'suggestions' && pending > 0 ? '$pending' : null,
              ),
            section(''),
            if (docs)
              item(
                const _Nav(
                  'files',
                  'Personal Files',
                  Icons.description_outlined,
                ),
              ),
            item(const _Nav('settings', 'Settings', Icons.settings_outlined)),
          ],
        ),
      );
    }
    return SizedBox(
      width: 232,
      child: ListView(
        padding: const EdgeInsets.only(top: 8, bottom: 8),
        children: [
          for (final n in _main)
            item(
              n,
              count: switch (n.id) {
                'library' => fmtNumber(stats['tracks'] ?? 0),
                'crates' => crates.isEmpty ? null : '${crates.length}',
                'health' => problems > 0 ? '$problems' : null,
                _ => null,
              },
              warn: n.id == 'health',
            ),
          section('Create'),
          for (final n in _create) item(n),
          section('Prepare'),
          for (final n in _prepare)
            item(
              n,
              count: n.id == 'suggestions' && pending > 0 ? '$pending' : null,
            ),
          section(
            'My crates',
            trailing: IconButton(
              tooltip: 'New crate',
              iconSize: 18,
              onPressed: () => showCrateDialog(context, ref),
              icon: const Icon(Icons.add),
            ),
          ),
          if (crates.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Text(
                'No crates yet. Try a template under Virtual Crates.',
                style: TextStyle(fontSize: DjType.small, color: t.faint),
              ),
            ),
          ...tree(null, 0),
          section(
            'Sources',
            trailing: IconButton(
              iconSize: 18,
              onPressed: () => setState(() => sources = !sources),
              icon: Icon(sources ? Icons.expand_more : Icons.chevron_right),
            ),
          ),
          if (sources)
            for (final r in roots)
              ListTile(
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 18),
                selected: view.id == 'root' && view.rootId == r.id,
                leading: const Icon(Icons.storage_outlined, size: 18),
                minLeadingWidth: 18,
                title: Tooltip(
                  message: r.path,
                  child: Text(
                    r.label ?? r.path,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                trailing: Icon(
                  Icons.circle,
                  size: 9,
                  color: r.status == 'offline' ? t.warn : t.ok,
                ),
                onTap: () =>
                    ref.read(viewProvider.notifier).go('root', rootId: r.id),
              ),
          if (sources && roots.isEmpty)
            ListTile(
              dense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 18),
              leading: const Icon(Icons.add, size: 16),
              title: const Text('Add a music folder'),
              onTap: () => ref.read(viewProvider.notifier).go('activity'),
            ),
          const Divider(height: 24),
          if (docs)
            item(
              const _Nav('files', 'Personal Files', Icons.description_outlined),
            ),
          item(const _Nav('settings', 'Settings', Icons.settings_outlined)),
        ],
      ),
    );
  }
}

/// A sidebar entry: hover, focus and press states, an animated selection
/// marker, and a tooltip with the name when only the icon shows.
class _NavItem extends StatefulWidget {
  const _NavItem({
    required this.nav,
    required this.selected,
    required this.rail,
    required this.onTap,
    this.count,
    this.warn = false,
  });
  final _Nav nav;
  final bool selected, rail, warn;
  final String? count;
  final VoidCallback onTap;
  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = DjTokens.of(context);
    final text = Theme.of(context).textTheme;
    final on = widget.selected;
    final fg = on ? t.accent : (_hover ? t.text : t.muted);
    final badge = widget.count == null
        ? null
        : Text(
            widget.count!,
            style: text.labelMedium?.copyWith(
              color: widget.warn ? t.warn : t.faint,
              fontFeatures: DjType.tabular,
            ),
          );
    Widget body = AnimatedContainer(
      duration: Motion.fast(context),
      curve: Motion.standard,
      height: 36,
      padding: EdgeInsets.symmetric(horizontal: widget.rail ? 0 : Space.x3),
      decoration: BoxDecoration(
        color: on
            ? t.tint(t.accent, 0.13)
            : (_hover ? t.text.withValues(alpha: 0.05) : Colors.transparent),
        borderRadius: Radii.medium,
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned(
            left: 0,
            top: 9,
            bottom: 9,
            child: AnimatedContainer(
              duration: Motion.base(context),
              curve: Motion.emphasized,
              width: 3,
              transform: Matrix4.diagonal3Values(1, on ? 1 : 0, 1),
              transformAlignment: Alignment.center,
              decoration: BoxDecoration(
                color: t.accent,
                borderRadius: Radii.small,
              ),
            ),
          ),
          if (widget.rail)
            Badge(
              isLabelVisible: widget.count != null,
              backgroundColor: widget.warn ? t.warn : t.accent,
              smallSize: 7,
              child: Icon(widget.nav.icon, size: IconSizes.md + 1, color: fg),
            )
          else
            Row(
              children: [
                const SizedBox(width: Space.x1),
                Icon(widget.nav.icon, size: IconSizes.md + 1, color: fg),
                const SizedBox(width: Space.x3),
                Expanded(
                  child: Text(
                    widget.nav.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodyMedium?.copyWith(
                      color: on ? t.accent : t.text,
                      fontWeight: on ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ),
                ?badge,
              ],
            ),
        ],
      ),
    );
    if (widget.rail) {
      body = Tooltip(
        message: widget.count == null
            ? widget.nav.label
            : '${widget.nav.label} (${widget.count})',
        preferBelow: false,
        verticalOffset: 0,
        margin: const EdgeInsets.only(left: 64),
        child: body,
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Space.x2, vertical: 1),
      child: Semantics(
        button: true,
        selected: on,
        label: widget.nav.label,
        excludeSemantics: widget.rail,
        child: MouseRegion(
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: Radii.medium,
              onTap: widget.onTap,
              child: body,
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusBar extends ConsumerWidget {
  const _StatusBar();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = DjTokens.of(context);
    final s = ref.watch(sessionProvider);
    final on = ref.watch(onlineOnProvider);
    final sc = s.lastScan;
    final scanning =
        sc != null && (sc.state == 'running' || sc.state == 'paused');
    final active = [
      for (final JobState j in s.jobs.all())
        if (j.state == 'running' || j.state == 'paused') j,
    ];
    TextStyle st() => TextStyle(fontSize: DjType.caption, color: t.faint);
    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: t.line)),
      ),
      child: Row(
        children: [
          Icon(Icons.circle, size: 8, color: t.ok),
          const SizedBox(width: 6),
          Text('Local catalogue', style: st()),
          const SizedBox(width: 16),
          Tooltip(
            message: 'Music files are only read. The optional tag writer needs your approval for every change.',
            child: Row(
              children: [
                Icon(Icons.lock_outline, size: 13, color: t.faint),
                const SizedBox(width: 4),
                Text('Source files read-only', style: st()),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Tooltip(
            message: on.isEmpty
                ? 'No online services are turned on'
                : 'On: ${on.join(', ')}',
            child: Row(
              children: [
                Icon(
                  Icons.circle,
                  size: 8,
                  color: on.isEmpty ? t.faint : t.accent,
                ),
                const SizedBox(width: 6),
                Text(
                  on.isEmpty
                      ? 'Online services off'
                      : 'Online: ${on.join(', ')}',
                  style: st(),
                ),
              ],
            ),
          ),
          if (scanning) ...[
            const SizedBox(width: 16),
            InkWell(
              onTap: () => ref.read(viewProvider.notifier).go('activity'),
              child: Text(
                '${sc.state == 'paused' ? 'Scan paused' : 'Scanning'} ${sc.filesProcessed + sc.unchanged}/${sc.filesFound}',
                style: st(),
              ),
            ),
            const SizedBox(width: 6),
            SizedBox(
              width: 80,
              child: LinearProgressIndicator(
                value: sc.filesToRead > 0
                    ? sc.filesProcessed / sc.filesToRead
                    : null,
              ),
            ),
          ],
          for (final j in active) ...[
            const SizedBox(width: 14),
            InkWell(
              onTap: () => ref.read(viewProvider.notifier).go(switch (j.kind) {
                'gigpack' => 'gig-pack',
                'docs' => 'files',
                'analysis' || 'hash' => 'activity',
                'pack:stems-ai' || 'ai_pack' || 'ai_model' => 'settings',
                _ => 'suggestions',
              }),
              child: Text(
                '${j.state == 'paused' ? '⏸' : '⟳'} ${j.kind} ${j.done}/${j.total}',
                style: st(),
              ),
            ),
          ],
          const Spacer(),
          Text('v$appVersion', style: st()),
        ],
      ),
    );
  }
}

/// Crates by id, for screens that need one.
Crate? crateById(List<Crate> crates, int? id) =>
    id == null ? null : crates.where((c) => c.id == id).firstOrNull;
