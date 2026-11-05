import 'package:flutter/material.dart';

import 'theme.dart';

/// Every screen of DJ Assistant, grouped as in the 1.x sidebar.
enum Page {
  library('Library', Icons.library_music_outlined, 'Library'),
  quickPrep('Quick Prep', Icons.bolt_outlined, 'Library'),
  health('Library Health', Icons.favorite_outline, 'Library'),
  organise('Organise Files', Icons.build_outlined, 'Library'),
  stems('Stems', Icons.layers_outlined, 'Create'),
  remix('Remix', Icons.shuffle, 'Create'),
  decks('DJ Decks', Icons.headphones_outlined, 'Create'),
  synth('Synth Lab', Icons.graphic_eq, 'Create'),
  drums('Drum Lab', Icons.album_outlined, 'Create'),
  setStudio('Set Studio', Icons.queue_music_outlined, 'Prepare'),
  discovery('Discovery', Icons.explore_outlined, 'Prepare'),
  suggestions('Suggestions', Icons.auto_fix_high_outlined, 'Prepare'),
  gig('Gig Mode', Icons.sensors, 'Prepare'),
  gigPack('Gig Pack', Icons.usb_outlined, 'Prepare'),
  settings('Settings', Icons.settings_outlined, '');

  const Page(this.label, this.icon, this.group);
  final String label;
  final IconData icon;
  final String group;
}

class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  Page page = Page.library;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          const _TitleBar(),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Sidebar(
                  current: page,
                  onPick: (p) => setState(() => page = p),
                ),
                const VerticalDivider(width: 1),
                Expanded(child: _Placeholder(page: page)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TitleBar extends StatelessWidget {
  const _TitleBar();
  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: line)),
      ),
      child: const Row(
        children: [
          Icon(Icons.graphic_eq, color: mint, size: 20),
          SizedBox(width: 8),
          Text(
            'DJ Assistant',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
          ),
          Spacer(),
          Text(
            '2.0 preview',
            style: TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.current, required this.onPick});
  final Page current;
  final ValueChanged<Page> onPick;

  @override
  Widget build(BuildContext context) {
    final items = <Widget>[];
    String? group;
    for (final p in Page.values) {
      if (p.group != group && p.group.isNotEmpty) {
        items.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
            child: Text(
              p.group.toUpperCase(),
              style: const TextStyle(
                fontSize: 11,
                letterSpacing: 1.2,
                color: Colors.white54,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        );
      }
      group = p.group;
      final on = p == current;
      items.add(
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
          child: ListTile(
            dense: true,
            selected: on,
            selectedTileColor: mint.withValues(alpha: 0.12),
            selectedColor: mint,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            leading: Icon(p.icon, size: 20),
            title: Text(p.label),
            onTap: () => onPick(p),
          ),
        ),
      );
    }
    return SizedBox(width: 240, child: ListView(children: items));
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.page});
  final Page page;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            page.label,
            style: Theme.of(context).textTheme.headlineMedium
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          const Text(
            'Being rebuilt in Flutter for DJ Assistant 2.0.',
            style: TextStyle(color: Colors.white60),
          ),
        ],
      ),
    );
  }
}
