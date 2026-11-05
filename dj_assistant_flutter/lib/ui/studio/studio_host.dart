import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state.dart';
import '../widgets.dart';
import 'common.dart';
import 'dj_page.dart';
import 'remix_page.dart';
import 'sound_lab.dart';
import 'stems_page.dart';

const studioTabs = [
  (
    'stems',
    'Stems',
    'Vocals, drums, bass, melodies · key, tempo, chords · MIDI',
  ),
  ('remix', 'Remix', 'Mash up songs and stems, auto-synced'),
  ('dj', 'DJ Decks', 'Two decks with auto beat-matching'),
  ('synth', 'Synth Lab', 'Make an instrument from words'),
  ('drums', 'Drum Lab', 'Make a drum kit from words'),
];

/// The Studio (Stems, Remix, DJ Decks, Synth Lab, Drum Lab). Pages are built
/// the first time they are opened and then stay mounted, so playing decks and
/// loaded remixes survive switching pages — and leaving the Studio.
class StudioHost extends ConsumerStatefulWidget {
  const StudioHost({super.key});
  @override
  ConsumerState<StudioHost> createState() => _StudioHostState();
}

class _StudioHostState extends ConsumerState<StudioHost> {
  final opened = <String>{};

  @override
  Widget build(BuildContext context) {
    ref.listen(handoffProvider, (_, h) {
      if (h != null) ref.read(viewProvider.notifier).go('studio:${h.page}');
    });
    final view = ref.watch(viewProvider);
    final tab = view.id.startsWith('studio:') ? view.id.substring(7) : null;
    if (tab != null) opened.add(tab);
    final index = studioTabs.indexWhere((t) => t.$1 == tab);
    return IndexedStack(
      index: index < 0 ? 0 : index,
      children: [
        for (final (id, label, hint) in studioTabs)
          opened.contains(id)
              ? PageFrame(
                  title: label,
                  subtitle: hint,
                  child: switch (id) {
                    'stems' => const StemsPage(),
                    'remix' => RemixPage(active: tab == 'remix'),
                    'dj' => const DjPage(),
                    'synth' => SynthLab(active: tab == 'synth'),
                    _ => DrumLab(active: tab == 'drums'),
                  },
                )
              : const SizedBox.shrink(),
      ],
    );
  }
}
