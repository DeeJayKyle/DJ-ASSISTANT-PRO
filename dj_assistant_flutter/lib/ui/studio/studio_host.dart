import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../widgets.dart';

/// The Studio (Stems, Remix, DJ Decks, Synth Lab, Drum Lab).
class StudioHost extends ConsumerWidget {
  const StudioHost({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => const EmptyState(
    icon: Icons.layers_outlined,
    title: 'Studio',
    message: 'The Studio pages are being ported to 2.0.',
  );
}
