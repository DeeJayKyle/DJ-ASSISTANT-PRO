import 'package:flutter/material.dart';

import 'analyse_screen.dart';
import 'backups_screen.dart';
import 'crates_screen.dart';
import 'home_screen.dart';
import 'library_screen.dart';
import 'library_tools.dart';
import 'serato_crates_screen.dart';
import 'settings_screen.dart';
import 'state.dart';

/// The page for a view id. Pages that are tabs of a hub (see hubs.dart) are
/// wrapped in its HubScope by the shell.
Widget screenFor(AppView v) => switch (v.id) {
  'crate' => LibraryScreen(
    key: ValueKey('crate${v.crateId}'),
    crateId: v.crateId,
  ),
  'root' => LibraryScreen(key: ValueKey('root${v.rootId}'), rootId: v.rootId),
  'home' => const HomeScreen(),
  'crates' => const CratesScreen(),
  'serato' => const SeratoCratesScreen(),
  'activity' => const ActivityScreen(),
  'health' => HealthScreen(fix: v.params?['fix'] as String?),
  'analyse' => const AnalyseScreen(),
  'suggestions' => const SuggestionsScreen(),
  'settings' => const SettingsScreen(),
  'backups' => const BackupsScreen(),
  _ => const LibraryScreen(key: ValueKey('library')),
};
