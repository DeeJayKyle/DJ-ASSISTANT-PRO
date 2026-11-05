import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'catalogue.dart';

/// Local accounts: several people or libraries on one computer, with no sign-in.
/// Same layout and `accounts.json` format as DJ Assistant 1.x:
///
///     <data>/accounts.json
///     <data>/catalogue.sqlite3                 the first account, from before accounts
///     <data>/accounts/<id>/catalogue.sqlite3
///
/// Only writes inside the data folder. Music files are never touched.
const legacyId = 'main';
const _colors = [
  '#3ee6c4',
  '#7aa2ff',
  '#ffb547',
  '#ff7aa8',
  '#b38cff',
  '#5cd1ff',
  '#9be15d',
  '#ff8a5c',
];

class Account {
  Account({
    required this.id,
    required this.name,
    required this.color,
    required this.createdAt,
  });
  final String id;
  String name;
  final String color;
  final int createdAt;

  factory Account.fromJson(Map<String, dynamic> j) => Account(
    id: j['id'] as String,
    name: j['name'] as String,
    color: j['color'] as String,
    createdAt: (j['created_at'] as num).toInt(),
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'color': color,
    'created_at': createdAt,
  };
}

class AccountException implements Exception {
  AccountException(this.message);
  final String message;
  @override
  String toString() => message;
}

class AccountsService {
  AccountsService._(this.base);
  final String base;
  final List<Account> _accounts = [];
  String? _last;
  String? _currentId;
  Catalogue? _current;

  /// Returns true while a scan, analysis or copy runs in the open account.
  bool Function() isBusy = () => false;

  /// Opens the accounts in [base]. A catalogue made before accounts existed becomes the
  /// first account; the last account used is opened again.
  factory AccountsService.open(String base) {
    Directory(base).createSync(recursive: true);
    final s = AccountsService._(base);
    s._read();
    if (s._accounts.isEmpty &&
        File(p.join(base, 'catalogue.sqlite3')).existsSync()) {
      s._accounts.add(
        Account(
          id: legacyId,
          name: 'My library',
          color: _colors[0],
          createdAt: nowMs(),
        ),
      );
      s._last = legacyId;
      s._write();
    }
    final last = s._accounts.any((a) => a.id == s._last)
        ? s._last
        : (s._accounts.isEmpty ? null : s._accounts.first.id);
    if (last != null) s.switchTo(last);
    return s;
  }

  String get _bookPath => p.join(base, 'accounts.json');

  void _read() {
    final f = File(_bookPath);
    if (!f.existsSync()) return;
    try {
      final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      _accounts
        ..clear()
        ..addAll(
          ((j['accounts'] as List?) ?? []).map(
            (a) => Account.fromJson(a as Map<String, dynamic>),
          ),
        );
      _last = j['last'] as String?;
    } on FormatException catch (e) {
      throw AccountException(
        'accounts.json is damaged (${e.message}); restore it from a backup or delete it to start again',
      );
    }
  }

  /// Written to a temporary file, then renamed, so a crash never leaves it half-written.
  void _write() {
    final tmp = File(p.join(base, 'accounts.json.tmp'));
    tmp.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'accounts': _accounts.map((a) => a.toJson()).toList(),
        'last': _last,
      }),
    );
    tmp.renameSync(_bookPath);
  }

  String cataloguePath(String id) => id == legacyId
      ? p.join(base, 'catalogue.sqlite3')
      : p.join(base, 'accounts', id, 'catalogue.sqlite3');

  List<Account> get accounts => List.unmodifiable(_accounts);
  String? get currentId => _currentId;

  /// The open account's catalogue, if any.
  Catalogue? get catalogue => _current;

  static String _clean(String name) {
    final n = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .join(' ');
    if (n.isEmpty) throw AccountException('give the account a name');
    if (n.runes.length > 40) {
      throw AccountException('keep the name under 40 characters');
    }
    if (n.runes.any((r) => r < 0x20 || (r >= 0x7f && r < 0xa0))) {
      throw AccountException("the name contains characters that can't be used");
    }
    return n;
  }

  void _ensureIdle() {
    if (_current != null && isBusy()) {
      throw AccountException(
        'a scan, analysis or copy is still running in this account; wait for it to finish or cancel it first',
      );
    }
  }

  Account switchTo(String id) {
    final acct = _accounts.where((a) => a.id == id).firstOrNull;
    if (acct == null) throw AccountException('that account no longer exists');
    if (_currentId == id) return acct;
    _ensureIdle();
    // Close the old catalogue before opening the new one.
    _current?.close();
    _current = null;
    _current = Catalogue.open(cataloguePath(id));
    _currentId = id;
    _last = id;
    _write();
    return acct;
  }

  Account create(String name) {
    final n = _clean(name);
    if (_accounts.any((a) => a.name.toLowerCase() == n.toLowerCase())) {
      throw AccountException('there is already an account called “$n”');
    }
    if (_accounts.length >= 50) {
      throw AccountException("that's a lot of accounts — remove one first");
    }
    final seed =
        '$n|${DateTime.now().microsecondsSinceEpoch}|${Random.secure().nextInt(1 << 32)}|$pid';
    final id = sha256.convert(utf8.encode(seed)).toString().substring(0, 12);
    final acct = Account(
      id: id,
      name: n,
      color: _colors[_accounts.length % _colors.length],
      createdAt: nowMs(),
    );
    _accounts.add(acct);
    _write();
    switchTo(acct.id);
    return acct;
  }

  Account rename(String id, String name) {
    final n = _clean(name);
    if (_accounts.any(
      (a) => a.id != id && a.name.toLowerCase() == n.toLowerCase(),
    )) {
      throw AccountException('there is already an account called “$n”');
    }
    final a = _accounts.where((a) => a.id == id).firstOrNull;
    if (a == null) throw AccountException('that account no longer exists');
    a.name = n;
    _write();
    return a;
  }

  /// Removes an account and its catalogue. Music files are not touched, and backups made
  /// by the tag writer are kept. Returns the backups folder if one was kept.
  String? delete(String id) {
    if (!_accounts.any((a) => a.id == id)) {
      throw AccountException('that account no longer exists');
    }
    if (_accounts.length == 1) {
      throw AccountException(
        'this is the only account; create another one before removing it',
      );
    }
    if (_currentId == id) {
      _ensureIdle();
      switchTo(_accounts.firstWhere((a) => a.id != id).id);
    }
    final path = cataloguePath(id);
    for (final suffix in ['', '-wal', '-shm']) {
      final f = File('$path$suffix');
      if (f.existsSync()) f.deleteSync();
    }
    final dir = Directory(p.dirname(path));
    final backups = Directory(p.join(dir.path, 'backups'));
    final kept = backups.existsSync() ? backups.path : null;
    if (id != legacyId) {
      // Only removed when nothing else (such as tag-write backups) is left in it.
      try {
        dir.deleteSync();
      } on FileSystemException {
        // not empty: keep it
      }
    }
    _accounts.removeWhere((a) => a.id == id);
    _write();
    return kept;
  }

  void close() {
    _current?.close();
    _current = null;
  }
}
