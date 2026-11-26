import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/gestures.dart'
    show kBackMouseButton, kForwardMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/accounts.dart';
import '../core/crates.dart';
import '../core/jobs.dart';
import '../online/http_online.dart' show appVersion;
import 'crates_screen.dart';
import 'format.dart';
import 'screens.dart';
import 'shortcuts_sheet.dart';
import 'state.dart';
import 'hubs.dart';
import 'theme.dart';
import 'widgets.dart';

class _Nav {
  const _Nav(this.id, this.label, this.icon);
  final String id, label;
  final IconData icon;
}

class NavPage {
  const NavPage(this.id, this.label, this.icon);
  final String id, label;
  final IconData icon;
}

/// Every page, hub by hub, for Go to (Ctrl+K). Ctrl+1…4 opens the hubs.
final allPages = [
  for (final h in hubs)
    for (final x in h.tabs) NavPage(x.id, x.pageTitle ?? x.label, x.icon),
  const NavPage('settings', 'Settings', Icons.settings_outlined),
];

/// Ctrl+K: type part of a page's name and press Enter to go there.
Future<void> showGoTo(BuildContext context, WidgetRef ref) async {
  final pick = await showDialog<String>(
    context: context,
    builder: (c) {
      var q = '';
      return StatefulBuilder(
        builder: (c, set) {
          final hits = [
            for (final p in allPages)
              if (p.label.toLowerCase().contains(q.toLowerCase())) p,
          ];
          return AlertDialog(
            title: const Text('Go to'),
            content: SizedBox(
              width: 420,
              height: 380,
              child: Column(
                children: [
                  TextField(
                    autofocus: true,
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: 'Page name',
                    ),
                    onChanged: (v) => set(() => q = v),
                    onSubmitted: (_) {
                      if (hits.isNotEmpty) Navigator.pop(c, hits.first.id);
                    },
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ListView(
                      children: [
                        for (final (i, p) in hits.indexed)
                          ListTile(
                            dense: true,
                            leading: Icon(p.icon, size: 18),
                            title: Text(p.label),
                            trailing: i == 0
                                ? const Text('Enter')
                                : switch (hubs.indexWhere(
                                    (h) => h.tabs.first.id == p.id,
                                  )) {
                                    -1 => null,
                                    final n => Text('Ctrl+${n + 1}'),
                                  },
                            onTap: () => Navigator.pop(c, p.id),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
  );
  if (pick != null) ref.read(viewProvider.notifier).go(pick);
}

class Shell extends ConsumerStatefulWidget {
  const Shell({super.key});
  @override
  ConsumerState<Shell> createState() => _ShellState();
}

class _ShellState extends ConsumerState<Shell> {
  bool _dragging = false;

  Future<void> _dropped(List<String> paths) async {
    setState(() => _dragging = false);
    if (paths.isEmpty) return;
    toast('Adding ${paths.length == 1 ? '1 item' : '${paths.length} items'}…');
    final msg = await guard(
      () => ref.read(sessionProvider).importMusic(paths),
      bump: ref,
    );
    if (msg != null) toast(msg);
  }

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
    // write-through: catalogue changes waiting for their files
    try {
      s.startFileSync();
    } on Object {
      // a busy database: next tick
    }
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
        final name = switch (j.kind) {
          'online' => 'Online analysis',
          'serato_sync' => 'Reading Serato BPM and key',
          'file_sync' => 'Writing to music files',
          _ => j.kind[0].toUpperCase() + j.kind.substring(1),
        };
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

  /// Ctrl+Tab / Ctrl+Shift+Tab: the next or previous tab of the open hub.
  void _stepTab(int step) {
    final next = stepTab(ref.read(viewProvider).id, step);
    if (next != null) ref.read(viewProvider.notifier).go(next);
  }

  @override
  Widget build(BuildContext context) {
    final view = ref.watch(viewProvider);
    final hub = hubOf(view.id);
    final page = screenFor(view);
    final body = hub != null && hub.owns(view.id)
        ? HubScope(
            hub: hub,
            current: view.id,
            onSelect: (id) => ref.read(viewProvider.notifier).go(id),
            child: page,
          )
        : page;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.f1): () =>
            showShortcuts(context),
        const SingleActivator(LogicalKeyboardKey.slash, control: true): () =>
            showShortcuts(context),
        // navigation
        const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true): () =>
            ref.read(viewProvider.notifier).back(),
        const SingleActivator(LogicalKeyboardKey.arrowRight, alt: true): () =>
            ref.read(viewProvider.notifier).forward(),
        const SingleActivator(LogicalKeyboardKey.browserBack): () =>
            ref.read(viewProvider.notifier).back(),
        const SingleActivator(LogicalKeyboardKey.browserForward): () =>
            ref.read(viewProvider.notifier).forward(),
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): () =>
            showGoTo(context, ref),
        const SingleActivator(LogicalKeyboardKey.keyP, control: true): () =>
            showGoTo(context, ref),
        const SingleActivator(LogicalKeyboardKey.comma, control: true): () =>
            ref.read(viewProvider.notifier).go('settings'),
        const SingleActivator(LogicalKeyboardKey.digit0, control: true): () =>
            ref.read(viewProvider.notifier).go('home'),
        const SingleActivator(LogicalKeyboardKey.home, alt: true): () =>
            ref.read(viewProvider.notifier).go('home'),
        const SingleActivator(LogicalKeyboardKey.tab, control: true): () =>
            _stepTab(1),
        const SingleActivator(LogicalKeyboardKey.pageDown, control: true): () =>
            _stepTab(1),
        const SingleActivator(
          LogicalKeyboardKey.tab,
          control: true,
          shift: true,
        ): () =>
            _stepTab(-1),
        const SingleActivator(LogicalKeyboardKey.pageUp, control: true): () =>
            _stepTab(-1),
        for (final (i, h) in hubs.indexed)
          SingleActivator(
            LogicalKeyboardKey(LogicalKeyboardKey.digit1.keyId + i),
            control: true,
          ): () =>
              ref.read(viewProvider.notifier).go(h.tabs.first.id),
      },
      // the mouse's back and forward side buttons
      child: Listener(
        onPointerDown: (e) {
          if (e.buttons & kBackMouseButton != 0) {
            ref.read(viewProvider.notifier).back();
          } else if (e.buttons & kForwardMouseButton != 0) {
            ref.read(viewProvider.notifier).forward();
          }
        },
        child: DropTarget(
          onDragEntered: (_) => setState(() => _dragging = true),
          onDragExited: (_) => setState(() => _dragging = false),
          onDragDone: (d) => _dropped([for (final f in d.files) f.path]),
          child: Focus(
            autofocus: true,
            child: DecoratedBox(
              position: DecorationPosition.foreground,
              decoration: _dragging
                  ? BoxDecoration(
                      border: Border.all(
                        color: DjTokens.of(context).accent,
                        width: 3,
                      ),
                    )
                  : const BoxDecoration(),
              child: Scaffold(
                body: LayoutBuilder(
                  builder: (context, box) {
                    final rail = box.maxWidth < 1240;
                    return Column(
                      children: [
                        const _TitleBar(),
                        Expanded(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _Sidebar(rail: rail),
                              const VerticalDivider(width: 1),
                              Expanded(child: body),
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
    ref.watch(viewProvider); // back/forward buttons follow navigation
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
          IconButton(
            tooltip: 'Back (Alt+Left)',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.arrow_back, size: 18),
            onPressed: ref.read(viewProvider.notifier).canGoBack
                ? () => ref.read(viewProvider.notifier).back()
                : null,
          ),
          IconButton(
            tooltip: 'Forward (Alt+Right)',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.arrow_forward, size: 18),
            onPressed: ref.read(viewProvider.notifier).canGoForward
                ? () => ref.read(viewProvider.notifier).forward()
                : null,
          ),
          IconButton(
            tooltip: 'Go to a page (Ctrl+K)',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.search, size: 18),
            onPressed: () => showGoTo(context, ref),
          ),
          const SizedBox(width: 4),
          Image.asset(
            'assets/icon/app_icon_256.png',
            width: 22,
            height: 22,
            filterQuality: FilterQuality.medium,
          ),
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
    final problems =
        (stats['errors'] ?? 0) +
        (stats['missing'] ?? 0) +
        (stats['low_bitrate'] ?? 0);
    Widget item(_Nav n, {String? count, bool warn = false}) => _NavItem(
      nav: n,
      selected: view.id == n.id,
      rail: widget.rail,
      count: count,
      warn: warn,
      onTap: () => ref.read(viewProvider.notifier).go(n.id),
    );
    final here = hubOf(view.id);
    final homeItem = _NavItem(
      nav: const _Nav('home', 'Home', Icons.dashboard_outlined),
      color: homeColor(context),
      hint: homePage.hint,
      selected: view.id == 'home',
      rail: widget.rail,
      onTap: () => ref.read(viewProvider.notifier).go('home'),
    );
    // One entry per hub; it opens the hub's first tab.
    Widget hubItem(Hub h) {
      final (count, warn) = switch (h.id) {
        'hub:library' => (fmtNumber(stats['tracks'] ?? 0), false),
        'hub:analysis' when pending > 0 => ('$pending', false),
        'hub:analysis' when problems > 0 => ('$problems', true),
        'hub:crates' when crates.isNotEmpty => ('${crates.length}', false),
        _ => (null, false),
      };
      final i = hubs.indexOf(h);
      return _NavItem(
        nav: _Nav(h.id, h.label, h.icon),
        color: h.color(context),
        hint:
            '${h.hint}\nCtrl+${i + 1} · tabs: '
            '${h.tabs.map((x) => x.label).join(', ')}',
        selected: identical(here, h),
        rail: widget.rail,
        count: widget.rail && h.id == 'hub:library' ? null : count,
        warn: warn,
        onTap: () => ref.read(viewProvider.notifier).go(h.tabs.first.id),
      );
    }

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
            homeItem,
            for (final h in hubs) hubItem(h),
            section(''),
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
          homeItem,
          for (final h in hubs) hubItem(h),
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
    this.color,
    this.hint,
  });
  final _Nav nav;
  final Color? color;
  final String? hint;
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
    final hue = widget.color ?? t.accent;
    final fg = widget.color ?? (on ? t.accent : (_hover ? t.text : t.muted));
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
            ? t.tint(hue, 0.16)
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
              decoration: BoxDecoration(color: hue, borderRadius: Radii.small),
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
                      color: on ? hue : t.text,
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
    if (widget.rail || widget.hint != null) {
      final name = widget.count == null
          ? widget.nav.label
          : '${widget.nav.label} (${widget.count})';
      body = Tooltip(
        message: widget.hint == null ? name : '$name\n${widget.hint}',
        waitDuration: Duration(milliseconds: widget.rail ? 0 : 400),
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
          Builder(
            builder: (context) {
              final set = ref.watch(settingsProvider);
              final organise = set['organise_mode'] == true;
              final tags = set['allow_file_changes'] == true;
              final sync = set['sync_to_files'] == true;
              final writable = organise || tags || sync;
              return Tooltip(
                message: sync
                    ? 'Your changes to title, artist, album, genre, year, BPM and key are written into the music files, each after a verified backup, and can be rolled back. Turn it off in Settings → Changes to music files.'
                    : writable
                    ? '${organise ? 'Organise Files mode' : 'Tag writing'} is on: music files can change, but only after a preview you approve, with a verified backup or restorable copy. Turn it off in Settings → Changes to music files.'
                    : 'Music files are only read. Tag writing and Organise Files mode are off.',
                child: Row(
                  children: [
                    Icon(
                      writable ? Icons.lock_open_outlined : Icons.lock_outline,
                      size: 13,
                      color: writable ? t.warn : t.faint,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      sync
                          ? 'Changes write to files'
                          : writable
                          ? (organise ? 'Organise mode on' : 'Tag writing on')
                          : 'Source files read-only',
                      style: writable ? st().copyWith(color: t.warn) : st(),
                    ),
                  ],
                ),
              );
            },
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
                'analysis' || 'hash' => 'activity',
                'online' || 'serato_sync' => 'analyse',
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
