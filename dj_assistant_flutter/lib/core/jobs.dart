import 'dart:async';
import 'dart:isolate';

import 'catalogue.dart';
import 'diag_log.dart';

/// Background jobs (analysis, lookups, exports…), ported from 1.x `jobs.rs`: one
/// job per kind at a time, each in its own isolate, pausable and cancellable, with
/// progress streamed back. Gig mode pauses every job at once.
class JobState {
  JobState(this.kind);
  final String kind;
  String state =
      'idle'; // idle | running | paused | completed | cancelled | failed
  int done = 0, total = 0, errors = 0;
  String? message;
  int? startedAt, finishedAt;
  Object? result;

  Map<String, Object?> toJson() => {
    'kind': kind,
    'state': state,
    'done': done,
    'total': total,
    'errors': errors,
    'message': message,
    'started_at': startedAt,
    'finished_at': finishedAt,
    'result': result,
  };
}

class JobBusyException implements Exception {
  JobBusyException(this.kind);
  final String kind;
  @override
  String toString() => '$kind is already running';
}

/// What a job body sees inside its isolate.
/// What a long task reports while it runs. [JobContext] is the isolate-backed
/// one; [LocalProgress] runs a task in place (tests, small inline lookups).
abstract interface class JobProgress {
  set total(int n);
  void tick({bool ok = true});
  set message(String m);
  Future<bool> checkpoint();
}

class LocalProgress implements JobProgress {
  int totalCount = 0, done = 0, errors = 0;
  final messages = <String>[];
  bool cancelled = false;
  @override
  set total(int n) => totalCount = n;
  @override
  void tick({bool ok = true}) {
    done++;
    if (!ok) errors++;
  }

  @override
  set message(String m) => messages.add(m);
  @override
  Future<bool> checkpoint() async => cancelled;
}

class JobContext implements JobProgress {
  JobContext._(this._out);
  final SendPort _out;
  bool cancelled = false;
  bool paused = false;
  int _done = 0, _total = 0, _errors = 0;
  String? _message;
  Object? _result;
  var _lastSent = 0;

  @override
  set total(int n) {
    _total = n;
    _send(force: true);
  }

  @override
  void tick({bool ok = true}) {
    _done++;
    if (!ok) _errors++;
    _send();
  }

  /// Sets the done count directly (downloads report bytes done of total).
  void progressTo(int done) {
    _done = done;
    _send();
  }

  @override
  set message(String m) {
    _message = m;
    _send(force: true);
  }

  set result(Object? r) => _result = r;

  /// Lets control messages in, waits while paused; true when cancelled.
  @override
  Future<bool> checkpoint() async {
    await Future<void>.delayed(Duration.zero);
    while (paused && !cancelled) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return cancelled;
  }

  void _send({bool force = false}) {
    final now = nowMs();
    if (!force && now - _lastSent < 100) return;
    _lastSent = now;
    _out.send({
      'done': _done,
      'total': _total,
      'errors': _errors,
      'message': _message,
    });
  }
}

typedef JobBody = Future<void> Function(JobContext ctx);

class _Entry {
  _Entry(this.state);
  final JobState state;
  SendPort? control;
  bool paused = false;
  Completer<JobState>? done;
}

class JobsController {
  final _jobs = <String, _Entry>{};
  final _changes = StreamController<JobState>.broadcast();

  /// Every progress change of every job.
  Stream<JobState> get changes => _changes.stream;

  bool running(String kind) => _jobs[kind]?.done?.isCompleted == false;
  bool get anyRunning => _jobs.keys.any(running);

  JobState status(String kind) {
    final e = _jobs[kind];
    if (e == null) return JobState(kind);
    return e.state;
  }

  List<JobState> all() => [for (final k in _jobs.keys) status(k)];

  /// Starts [body] in a new isolate. It may only capture sendable values (paths,
  /// ids, settings), never open database handles.
  Future<JobState> start(
    String kind,
    JobBody body, {
    bool paused = false,
  }) async {
    if (running(kind)) throw JobBusyException(kind);
    final st = JobState(kind)
      ..state = paused ? 'paused' : 'running'
      ..startedAt = nowMs();
    final e = _Entry(st)
      ..paused = paused
      ..done = Completer<JobState>();
    _jobs[kind] = e;
    final port = ReceivePort(), exit = ReceivePort(), errors = ReceivePort();
    void finish(String state, [String? message]) {
      if (e.done!.isCompleted) return;
      st
        ..state = state
        ..finishedAt = nowMs();
      if (message != null) st.message = message;
      e.control = null;
      port.close();
      exit.close();
      errors.close();
      _changes.add(st);
      e.done!.complete(st);
    }

    port.listen((m) {
      if (m is SendPort) {
        e.control = m;
        if (e.paused) m.send('pause');
      } else if (m is Map) {
        st
          ..done = m['done'] as int
          ..total = m['total'] as int
          ..errors = m['errors'] as int
          ..message = m['message'] as String? ?? st.message;
        if (m.containsKey('outcome')) {
          st.result = m['result'];
          finish(m['outcome'] as String, m['error'] as String?);
          return;
        }
        st.state = e.paused ? 'paused' : 'running';
        _changes.add(st);
      }
    });
    errors.listen(
      (err) => finish('failed', 'internal error: ${(err as List).first}'),
    );
    exit.listen((_) => finish('failed', 'the job stopped unexpectedly'));
    try {
      await Isolate.spawn(
        _jobMain,
        (port.sendPort, body, paused),
        onError: errors.sendPort,
        onExit: exit.sendPort,
      );
    } on Object catch (err, stack) {
      // e.g. the job captured something that can't be sent to an isolate:
      // report it instead of showing the job as running forever
      DiagLog.error('jobs', '$kind could not start: $err', stack);
      finish('failed', "couldn't start: $err");
    }
    return e.done!.future;
  }

  void cancel(String kind) {
    final e = _jobs[kind];
    if (e == null) return;
    e.paused = false;
    e.control?.send('cancel');
  }

  void pause(String kind, bool paused) {
    final e = _jobs[kind];
    if (e == null || !running(kind)) return;
    e.paused = paused;
    e.state.state = paused ? 'paused' : 'running';
    e.control?.send(paused ? 'pause' : 'resume');
    _changes.add(e.state);
  }

  /// Gig mode: pause (or resume) every job.
  void pauseAll(bool paused) {
    for (final k in _jobs.keys) {
      pause(k, paused);
    }
  }

  Future<void> shutdown() async {
    final waits = <Future<void>>[];
    for (final k in _jobs.keys) {
      if (running(k)) {
        cancel(k);
        waits.add(_jobs[k]!.done!.future);
      }
    }
    await Future.wait(waits);
    await _changes.close();
  }
}

Future<void> _jobMain((SendPort, JobBody, bool) args) async {
  final (out, body, startPaused) = args;
  // Start paused when asked, so not even one item is processed before the
  // pause message could arrive.
  final ctx = JobContext._(out)..paused = startPaused;
  final control = ReceivePort();
  out.send(control.sendPort);
  control.listen((m) {
    switch (m) {
      case 'pause':
        ctx.paused = true;
      case 'resume':
        ctx.paused = false;
      case 'cancel':
        ctx.cancelled = true;
        ctx.paused = false;
    }
  });
  var outcome = 'completed';
  String? error;
  try {
    await body(ctx);
    if (ctx.cancelled) outcome = 'cancelled';
  } catch (e) {
    outcome = 'failed';
    error = '$e';
  }
  out.send({
    'done': ctx._done,
    'total': ctx._total,
    'errors': ctx._errors,
    'message': ctx._message,
    'outcome': outcome,
    'error': error,
    'result': ctx._result,
  });
  control.close();
}
