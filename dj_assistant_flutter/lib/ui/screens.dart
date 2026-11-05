import 'package:flutter/material.dart';

import 'crates_screen.dart';
import 'files_screens.dart';
import 'library_screen.dart';
import 'library_tools.dart';
import 'prepare_screens.dart';
import 'quick_prep_screen.dart';
import 'settings_screen.dart';
import 'state.dart';

export 'studio/studio_host.dart' show StudioHost;

/// The page for a view id (Studio pages live in [StudioHost], which stays
/// mounted so decks keep playing while the DJ looks elsewhere).
Widget screenFor(AppView v) => switch (v.id) {
  'crate' => LibraryScreen(
    key: ValueKey('crate${v.crateId}'),
    crateId: v.crateId,
  ),
  'root' => LibraryScreen(key: ValueKey('root${v.rootId}'), rootId: v.rootId),
  'quick' => const QuickPrepScreen(),
  'crates' => const CratesScreen(),
  'duplicates' => const DuplicatesScreen(),
  'activity' => const ActivityScreen(),
  'health' => HealthScreen(fix: v.params?['fix'] as String?),
  'organize' => const OrganiseScreen(),
  'set-studio' => SetStudioScreen(params: v.params),
  'discovery' => const DiscoveryScreen(),
  'suggestions' => const SuggestionsScreen(),
  'gig' => const GigScreen(),
  'gig-pack' => const GigPackScreen(),
  'files' => const FilesScreen(),
  'settings' => const SettingsScreen(),
  _ => const LibraryScreen(key: ValueKey('library')),
};
