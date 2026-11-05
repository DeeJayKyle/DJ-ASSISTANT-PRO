import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../app/session.dart';
import '../core/accounts.dart';
import '../core/crates.dart';
import '../core/library_edit.dart';
import '../core/roots.dart';
import '../online/online.dart';

/// Where 1.x keeps its data (Tauri's app data folder for
/// `com.deejaykyle.djassistant`), so 2.0 opens the same catalogues.
String defaultDataDir() {
  final env = Platform.environment;
  const id = 'com.deejaykyle.djassistant';
  if (Platform.isWindows) return p.join(env['APPDATA'] ?? '.', id);
  if (Platform.isMacOS) {
    return p.join(env['HOME'] ?? '.', 'Library', 'Application Support', id);
  }
  return p.join(
    env['XDG_DATA_HOME'] ?? p.join(env['HOME'] ?? '.', '.local', 'share'),
    id,
  );
}

/// Overridden at start-up (main) and in tests.
final accountsProvider = Provider<AccountsService>(
  (ref) => throw UnimplementedError('accountsProvider is set in main'),
);

/// How sessions are made (tests inject fakes for the online services).
final sessionFactoryProvider = Provider<AppSession Function(String dbPath)>(
  (ref) =>
      (dbPath) => AppSession(dbPath: dbPath),
);

class SessionNotifier extends Notifier<AppSession> {
  @override
  AppSession build() {
    final accounts = ref.watch(accountsProvider);
    if (accounts.currentId == null) accounts.create('My library');
    final s = ref.read(sessionFactoryProvider)(
      accounts.cataloguePath(accounts.currentId!),
    );
    accounts.isBusy = () =>
        s.jobs.all().any((j) => j.state == 'running' || j.state == 'paused') ||
        (s.lastScan?.state == 'running');
    ref.onDispose(s.close);
    if (s.watcher.enabled) s.watcher.start();
    return s;
  }

  /// Opens another account (closing this one).
  void switchTo(String id) {
    ref.read(accountsProvider).switchTo(id);
    ref.invalidateSelf();
  }
}

final sessionProvider = NotifierProvider<SessionNotifier, AppSession>(
  SessionNotifier.new,
);

/// Bumped after every change so screens re-read the catalogue.
class Version extends Notifier<int> {
  @override
  int build() => 0;
  void bump() => state++;
}

final versionProvider = NotifierProvider<Version, int>(Version.new);

/// Which screen is open: an id ("library", "crate", "root", "studio:dj"…)
/// with the crate or folder it shows.
@immutable
class AppView {
  const AppView(this.id, {this.crateId, this.rootId, this.params});
  final String id;
  final int? crateId, rootId;
  final Map<String, Object?>? params;
  @override
  bool operator ==(Object other) =>
      other is AppView &&
      other.id == id &&
      other.crateId == crateId &&
      other.rootId == rootId;
  @override
  int get hashCode => Object.hash(id, crateId, rootId);
}

class ViewNotifier extends Notifier<AppView> {
  @override
  AppView build() => const AppView('library');
  void go(
    String id, {
    int? crateId,
    int? rootId,
    Map<String, Object?>? params,
  }) => state = AppView(id, crateId: crateId, rootId: rootId, params: params);
}

final viewProvider = NotifierProvider<ViewNotifier, AppView>(ViewNotifier.new);

/// What the Library shows: free text, rule filters and sort.
@immutable
class LibraryQuery {
  const LibraryQuery({
    this.text = '',
    this.filters,
    this.sort,
    this.desc = false,
    this.label,
  });
  final String text;
  final Map<String, Object?>? filters;
  final String? sort, label;
  final bool desc;
  LibraryQuery copyWith({
    String? text,
    Map<String, Object?>? filters,
    bool clearFilters = false,
    String? sort,
    bool? desc,
  }) => LibraryQuery(
    text: text ?? this.text,
    filters: clearFilters ? null : (filters ?? this.filters),
    sort: sort ?? this.sort,
    desc: desc ?? this.desc,
    label: label,
  );
}

class LibraryQueryNotifier extends Notifier<LibraryQuery> {
  @override
  LibraryQuery build() => const LibraryQuery();
  void set(LibraryQuery q) => state = q;
}

final libraryQueryProvider =
    NotifierProvider<LibraryQueryNotifier, LibraryQuery>(
      LibraryQueryNotifier.new,
    );

/// Assistant panel: open, full width or hidden.
class ChatModeNotifier extends Notifier<String> {
  @override
  String build() {
    final s = ref.watch(sessionProvider);
    return s.cat.getSetting('chat_open') == '0' ? 'hidden' : 'open';
  }

  void set(String mode) {
    state = mode;
    ref.read(sessionProvider).settings.set('chat_open', mode != 'hidden');
  }
}

final chatModeProvider = NotifierProvider<ChatModeNotifier, String>(
  ChatModeNotifier.new,
);

// ---- data, re-read whenever the version is bumped

final statsProvider = Provider<Map<String, int>>((ref) {
  ref.watch(versionProvider);
  return ref.watch(sessionProvider).library.stats();
});

final cratesProvider = Provider<List<Crate>>((ref) {
  ref.watch(versionProvider);
  return ref.watch(sessionProvider).crates.list();
});

final rootsProvider = Provider<List<Root>>((ref) {
  ref.watch(versionProvider);
  return ref.watch(sessionProvider).roots.list();
});

final settingsProvider = Provider<Map<String, Object?>>((ref) {
  ref.watch(versionProvider);
  return ref.watch(sessionProvider).settings.all();
});

final pendingSuggestionsProvider = Provider<int>((ref) {
  ref.watch(versionProvider);
  return ref.watch(sessionProvider).suggestions.counts()['pending'] ?? 0;
});

final onlineOnProvider = Provider<List<String>>((ref) {
  ref.watch(versionProvider);
  return [
    for (final s in ref.watch(sessionProvider).settings.services())
      if (s['enabled'] == true && s['id'] != 'updates') s['name']! as String,
  ];
});

// ---- messages

final messengerKey = GlobalKey<ScaffoldMessengerState>();

/// A short message at the bottom of the window.
void toast(String message, {bool error = false}) {
  final m = messengerKey.currentState;
  if (m == null) return;
  m
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? const Color(0xFF8E2C2C) : null,
        duration: Duration(milliseconds: error ? 6500 : 3400),
      ),
    );
}

/// Runs [f]; shows the error message as a toast instead of throwing. Returns
/// null when it failed.
Future<T?> guard<T>(
  FutureOr<T> Function() f, {
  String? done,
  WidgetRef? bump,
}) async {
  try {
    final r = await f();
    if (done != null) toast(done);
    bump?.read(versionProvider.notifier).bump();
    return r;
  } on Object catch (e) {
    toast(_plain(e), error: true);
    return null;
  }
}

String _plain(Object e) {
  final s = '$e';
  return s.startsWith('Exception: ') ? s.substring(11) : s;
}

extension OnlineOff on AppSession {
  bool get anyOnline => settings.services().any(
    (s) => s['enabled'] == true && s['id'] != 'updates',
  );
}

/// The online layer used by sessions made in tests (none).
Online noOnline() => NoOnline();
