import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/analysis_store.dart';
import '../core/autoprep.dart';
import '../core/catalogue.dart';
import '../core/crates.dart';
import '../core/dj_export.dart';
import '../core/file_sync.dart';
import '../core/health.dart';
import '../core/jobs.dart';
import '../core/library.dart';
import '../core/paths.dart';
import '../core/removal.dart';
import '../core/roots.dart';
import '../core/safe_write.dart';
import '../core/scanner.dart';
import '../core/serato.dart';
import '../core/serato_backup.dart';
import '../core/serato_library.dart';
import '../core/settings.dart';
import '../core/suggestions.dart';
import '../core/taggers.dart';
import '../core/templates.dart';
import '../core/watcher.dart';
import '../online/credentials.dart';
import '../online/http_online.dart';
import '../online/online.dart';
import 'analyse_job.dart';

/// Builds the online implementation inside a job's isolate (top-level, so it
/// can be sent there).
Online defaultOnline() => HttpOnline();

/// One open catalogue (one DJ account) with every service on it.
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

  /// Makes an [Online] inside background isolates.
  final Online Function() onlineFactory;

  late final ScanService scan;
  ScanProgress? lastScan;
  StreamSubscription<ScanProgress>? _scanSub;

  /// The account's data folder.
  String get dataDir => p.dirname(dbPath);

  late final library = LibraryService(cat);
  late final roots = RootsService(cat);
  late final crates = CratesService(cat);
  late final templates = TemplatesService(cat);
  late final health = HealthService(cat);
  late final suggestions = SuggestionsService(cat);
  late final analysis = AnalysisStore(cat);
  late final settings = SettingsService(cat, secrets);
  late final safeWrite = SafeWriteService(cat, dataDir);
  late final djExport = DjExportService(cat);
  late final serato = SeratoService(cat);
  late final removal = RemovalService(cat);
  late final taggers = TaggerService(cat, dataDir);
  late final watcher = FolderWatcher(cat);

  /// The `_Serato_` folders used: the one chosen in Settings, else every one
  /// found on this computer.
  List<String> get seratoDirs {
    final chosen = cat.getSetting('serato_dir') ?? '';
    if (chosen.isNotEmpty && Directory(chosen).existsSync()) return [chosen];
    return SeratoLibrary.find();
  }

  /// ZIP backups taken before every change to Serato's files.
  late final seratoBackups = SeratoBackups(p.join(dataDir, 'serato_backups'));

  /// [dir] as a Serato library whose changes are checked and backed up.
  SeratoLibrary seratoLibraryFor(String dir) =>
      SeratoLibrary(dir, backups: seratoBackups);

  /// The `_Serato_` folder crates are managed in (the first one found).
  SeratoLibrary? get seratoLibrary {
    final d = seratoDirs;
    return d.isEmpty ? null : seratoLibraryFor(d.first);
  }

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
    if (autoPrepEnabled(cat)) runAnalyse();
  }

  /// Music dropped onto the window: folders, and the folders of dropped
  /// files, become library folders (nothing is copied). Then they are scanned
  /// and, with auto-analyse on, analysed and tagged at once.
  Future<String> importMusic(List<String> paths) async {
    final folders = <String>{
      for (final x in paths)
        FileSystemEntity.isDirectorySync(x) ? x : p.dirname(x),
    };
    final rootIds = <int>{};
    final notes = <String>[];
    var added = 0;
    for (final f in folders) {
      try {
        rootIds.add(roots.add(f).id);
        added++;
      } on Exception catch (e) {
        // already a library folder (or inside one): just scan it
        final k = pathKey(f);
        final r = roots
            .list()
            .where(
              (r) => pathKey(r.path) == k || keyIsWithin(k, pathKey(r.path)),
            )
            .firstOrNull;
        if (r != null) {
          rootIds.add(r.id);
        } else {
          notes.add('$e');
        }
      }
    }
    if (rootIds.isEmpty) {
      return notes.isEmpty ? 'Nothing to add.' : notes.join(' · ');
    }
    try {
      await scan.start(rootIds: rootIds.toList());
    } on StateError {
      return 'A scan is already running; try again when it finishes.';
    }
    final prep = autoPrepEnabled(cat);
    if (prep) runAnalyse();
    return [
      if (added > 0) 'Added ${added == 1 ? 'a folder' : '$added folders'}',
      prep
          ? 'analysing and tagging the new songs now'
          : 'Auto-analyse is off, so press Analyse when ready',
      ...notes.take(3),
    ].join('; ');
  }

  Map<String, Object?> startAnalysis({List<int>? ids, bool force = false}) =>
      _launch('analysis', analysisJob(dbPath, only: ids, force: force));


  /// The Analyse button: Serato BPM/key, energy, every online analyser at
  /// once (majority wins) and writing into the files. After scans it runs
  /// on new and incomplete tracks by itself.
  Map<String, Object?> runAnalyse({String scope = 'new', List<int>? ids}) {
    final make = onlineFactory;
    final store = secrets is MemorySecrets ? secrets : null;
    final oneTagger = taggers.enabled('onetagger')
        ? taggers.path('onetagger')
        : null;
    return _launch(
      'online',
      analyseJob(
        AnalysePlan(
          dbPath: dbPath,
          dataDir: dataDir,
          scope: scope,
          ids: ids,
          seratoDirs: seratoDirs,
          oneTaggerExe: oneTagger,
          oneTaggerPlatforms: taggers.oneTaggerPlatforms,
          energy: settings.all()['energy_analysis'] == true,
        ),
        makeOnline: make,
        makeSecrets: () => store ?? platformSecrets(),
      ),
    );
  }

  /// Writes queued catalogue changes into the music files (write-through,
  /// file_sync.dart), in the background. No-op when nothing is queued.
  Map<String, Object?>? startFileSync() {
    if (!fileSyncOn(cat) || jobs.running('file_sync') || jobs.running('online')) {
      return null;
    }
    if (fileSyncQueued(cat) == 0) return null;
    return _launch('file_sync', fileSyncJob(dbPath, dataDir));
  }

  bool _closed = false;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _scanSub?.cancel();
    watcher.stop();
    scan.cancel();
    await jobs.shutdown();
    cat.close();
  }
}
