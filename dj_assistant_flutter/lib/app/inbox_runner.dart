import 'dart:async';
import 'dart:io';

import '../core/autoprep.dart';
import '../core/inbox.dart';
import '../core/jobs.dart';
import 'session.dart';

/// Runs auto-import for a session: watches the downloads folder, checks it
/// once a minute as well (folder events can be missed, for example on a
/// network drive), and for each batch of finished downloads runs the import
/// job, scans the Inbox folder, adds the new tracks to the Inbox crate and
/// starts auto-prep (analysis, beatgrids, confident fixes).
///
/// Nothing runs while gig mode is on, and only one batch runs at a time.
class InboxRunner {
  InboxRunner(this.s);
  final AppSession s;

  StreamSubscription<FileSystemEvent>? _sub;
  Timer? _sweep, _debounce;
  bool _busy = false;

  /// What the last check did, for Settings.
  String? lastMessage;
  int? lastAt;

  /// Called after a batch so the UI can refresh (Library, crates).
  void Function()? onImported;

  bool get enabled => InboxSettings.of(s.cat).enabled;
  bool get running => _busy;

  /// Starts watching when auto-import is on (stops first; safe to call again
  /// after a settings change).
  void start() {
    stop();
    final st = InboxSettings.of(s.cat);
    if (!st.enabled) return;
    final dir = Directory(st.downloads);
    if (dir.existsSync()) {
      try {
        _sub = dir.watch().listen((_) {
          _debounce?.cancel();
          // a download fires many events; check once it has gone quiet
          _debounce = Timer(
            const Duration(milliseconds: settleMs + 1500),
            () => unawaited(runNow()),
          );
        });
      } on FileSystemException {
        // the timer below still finds new files
      }
    }
    _sweep = Timer.periodic(
      const Duration(minutes: 1),
      (_) => unawaited(runNow()),
    );
    unawaited(runNow());
  }

  void stop() {
    unawaited(_sub?.cancel());
    _sub = null;
    _sweep?.cancel();
    _sweep = null;
    _debounce?.cancel();
    _debounce = null;
  }

  Future<void> _waitForScan() async {
    final end = DateTime.now().add(const Duration(minutes: 30));
    while (s.lastScan?.state == 'running' && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(seconds: 1));
    }
  }

  /// Imports whatever has finished downloading. Returns the job's summary.
  Future<String> runNow() async {
    if (_busy) return lastMessage ?? 'Already checking…';
    if (s.gig.active) return 'Paused in gig mode.';
    if (!enabled) return 'Auto-import is off.';
    _busy = true;
    try {
      final JobState st;
      try {
        st = await s.jobs.start('inbox', inboxJob(s.dbPath));
      } on JobBusyException {
        return lastMessage ?? 'Already checking…';
      }
      var msg = st.message ?? '';
      final r = st.result;
      if (st.state == 'completed' && r is Map) {
        final paths = (r['paths'] as List? ?? const []).cast<String>();
        final root = r['root_id'] as int?;
        if (paths.isNotEmpty && root != null) {
          await _waitForScan();
          try {
            await s.scan.start(rootIds: [root]);
          } on StateError {
            // another scan started meanwhile: wait for it, it covers ours
            await _waitForScan();
          }
          final added = InboxService(s.cat).addToCrate(paths);
          msg = '$msg Added $added to the "$inboxCrateName" crate.';
          if (autoPrepEnabled(s.cat) && !s.gig.active) s.runAutoPrep();
          onImported?.call();
        }
      } else if (st.state == 'failed') {
        msg = 'Auto-import failed: ${st.message ?? 'unknown error'}';
      }
      if (msg.isNotEmpty) {
        lastMessage = msg.trim();
        lastAt = DateTime.now().millisecondsSinceEpoch;
      }
      return lastMessage ?? 'No new downloads.';
    } finally {
      _busy = false;
    }
  }
}
