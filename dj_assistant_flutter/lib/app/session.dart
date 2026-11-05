import 'dart:async';

import 'package:path/path.dart' as p;

import '../core/analysis_store.dart';
import '../core/autoprep.dart';
import '../core/catalogue.dart';
import '../core/crates.dart';
import '../core/discovery.dart';
import '../core/dj_export.dart';
import '../core/duplicates.dart';
import '../core/export.dart';
import '../core/gig.dart';
import '../core/gigpack.dart';
import '../core/health.dart';
import '../core/jobs.dart';
import '../core/library.dart';
import '../core/organize.dart';
import '../core/roots.dart';
import '../core/safe_write.dart';
import '../core/scanner.dart';
import '../core/serato.dart';
import '../core/sets.dart';
import '../core/settings.dart';
import '../core/suggestions.dart';
import '../core/templates.dart';
import '../core/watcher.dart';
import '../online/credentials.dart';
import '../online/http_online.dart';
import '../online/lookups.dart';
import '../online/online.dart';

/// Builds the online implementation inside a job's isolate (top-level, so it
/// can be sent there).
Online defaultOnline() => HttpOnline();

/// One open catalogue (one DJ account) with every service on it. Widgets and
/// the assistant call these services directly; there is no command bridge.
class AppSession {
  AppSession({
    required this.dbPath,
    Online? online,
    Secrets? secrets,
    JobsController? jobs,
    this.onlineFactory = defaultOnline,
  }) : cat = Catalogue.open(dbPath),
       online = online ?? HttpOnline(),
       secrets = secrets ?? platformSecrets(),
       jobs = jobs ?? JobsController() {
    scan = ScanService(dbPath);
    _scanSub = scan.progress.listen((s) => lastScan = s);
  }

  final String dbPath;
  final Catalogue cat;
  final Online online;
  final Secrets secrets;
  final JobsController jobs;

  /// Makes an [Online] inside background isolates (auto-prep, lookups).
  final Online Function() onlineFactory;

  late final ScanService scan;
  ScanProgress? lastScan;
  StreamSubscription<ScanProgress>? _scanSub;

  /// The account's data folder (backups, packs, removed files area…).
  String get dataDir => p.dirname(dbPath);

  late final library = LibraryService(cat);
  late final roots = RootsService(cat);
  late final crates = CratesService(cat);
  late final templates = TemplatesService(cat);
  late final health = HealthService(cat);
  late final duplicates = DuplicatesService(cat);
  late final suggestions = SuggestionsService(cat);
  late final analysis = AnalysisStore(cat);
  late final settings = SettingsService(cat, secrets);
  late final discovery = DiscoveryService(cat);
  late final sets = SetsService(cat);
  late final gig = GigService(cat, jobs: jobs);
  late final safeWrite = SafeWriteService(cat, dataDir);
  late final organize = OrganizeService(cat, dataDir);
  late final exports = ExportService(cat);
  late final djExport = DjExportService(cat);
  late final gigPack = GigPackService(cat);
  late final serato = SeratoService(cat);
  late final watcher = FolderWatcher(cat);

  /// Starts a background job without waiting for it; errors land in its state.
  Map<String, Object?> _launch(String kind, JobBody body) {
    unawaited(jobs.start(kind, body).then((_) {}, onError: (Object _) {}));
    return {'started': kind};
  }

  Map<String, Object?> startScan({List<int>? rootIds}) {
    unawaited(
      scan.start(rootIds: rootIds).then((_) => _afterScan(), onError: (_) {}),
    );
    return {'started': 'scan'};
  }

  void _afterScan() {
    if (autoPrepEnabled(cat) && !gig.active) runAutoPrep();
  }

  Map<String, Object?> startAnalysis({List<int>? ids, bool force = false}) =>
      _launch('analysis', analysisJob(dbPath, only: ids, force: force));

  Map<String, Object?> startHash() => _launch('hash', hashJob(dbPath));

  Map<String, Object?> runAutoPrep() {
    final make = onlineFactory;
    final store = secrets is MemorySecrets ? secrets : null;
    return _launch(
      'auto_prep',
      autoPrepJob(
        dbPath,
        onlineSteps: [
          (c, ctx) =>
              autoPrepOnline(c, ctx, make(), store ?? platformSecrets()),
        ],
      ),
    );
  }

  /// Looks tracks up in the switched-on catalogues (a background job).
  Map<String, Object?> lookupCatalogs(List<int> ids) {
    if (!catalogSourcesOn(cat, secrets)) {
      throw SuggestionException(
        'Turn on Deezer & Apple Music, Spotify, GetSongBPM or YouTube in Settings → Online services first.',
      );
    }
    final make = onlineFactory;
    final store = secrets is MemorySecrets ? secrets : null;
    final path = dbPath;
    return _launch('catalogs', (ctx) async {
      final c = Catalogue.open(path);
      try {
        ctx.result = {
          'suggestions': await catalogLookup(
            c,
            make(),
            store ?? platformSecrets(),
            ids,
            ctx,
          ),
        };
      } finally {
        c.close();
      }
    });
  }

  Map<String, Object?> lookupMusicbrainz(List<int> ids) {
    requireService(cat, 'musicbrainz');
    final make = onlineFactory;
    final path = dbPath;
    return _launch('musicbrainz', (ctx) async {
      final c = Catalogue.open(path);
      try {
        await musicbrainzLookup(c, make(), ids, ctx);
      } finally {
        c.close();
      }
    });
  }

  /// AcoustID: the UI asks the DJ to confirm before calling this.
  Map<String, Object?> lookupAcoustid(
    List<int> ids, {
    required bool confirmed,
  }) {
    if (!confirmed) {
      throw SuggestionException(
        'Confirm the AcoustID lookup first: it sends an audio fingerprint of each track.',
      );
    }
    requireService(cat, 'acoustid');
    final make = onlineFactory;
    final store = secrets is MemorySecrets ? secrets : null;
    final path = dbPath;
    return _launch('acoustid', (ctx) async {
      final c = Catalogue.open(path);
      try {
        await acoustidLookup(c, make(), store ?? platformSecrets(), ids, ctx);
      } finally {
        c.close();
      }
    });
  }

  Future<void> close() async {
    await _scanSub?.cancel();
    watcher.stop();
    scan.cancel();
    await jobs.shutdown();
    cat.close();
  }
}
