import 'dart:convert';

import '../online/lookups.dart';
import '../online/online.dart';
import 'autoprep.dart';
import 'catalogue.dart';
import 'library.dart';

class SettingsException implements Exception {
  SettingsException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// App settings, online service switches and keys (1.x `get_settings`,
/// `set_setting`, `services`, `set_service`, `set_secret`, `delete_secret`).
/// Same keys and stored values as 1.x, so a 1.8 catalogue keeps its settings.
class SettingsService {
  SettingsService(this.cat, this.secrets);
  final Catalogue cat;
  final Secrets secrets;

  bool _flag(String k, bool def) {
    final v = cat.getSetting(k);
    return v == null ? def : v == '1';
  }

  Map<String, Object?> all() {
    Object? prefs;
    try {
      prefs = jsonDecode(cat.getSetting('ui_prefs') ?? '{}');
    } on FormatException {
      prefs = null;
    }
    return {
      'low_bitrate_kbps': LibraryService(cat).lowBitrateKbps,
      'theme': cat.getSetting('theme') ?? 'dark',
      'privacy_acknowledged': _flag('privacy_acknowledged', false),
      'sync_to_files': _flag('sync_to_files', true),
      'write_backups': _flag('write_backups', false),
      'watch_enabled': _flag('watch_enabled', false),
      'auto_update': _flag('auto_update', true),
      'surface': cat.getSetting('surface') ?? 'glass',
      'motion': cat.getSetting('motion') ?? 'full',
      'accent': cat.getSetting('accent') ?? 'mint',
      'key_notation': cat.getSetting('key_notation') ?? 'camelot',
      'premium_ui': _flag('premium_ui', false),
      'auto_prep': autoPrepEnabled(cat),
      'energy_analysis': _flag('energy_analysis', true),
      'serato_dir': cat.getSetting('serato_dir') ?? '',
      'ui_prefs': prefs is Map ? prefs : <String, Object?>{},
    };
  }

  Never _bad(String m) => throw SettingsException(m);

  static const flags = {
    'privacy_acknowledged',
    'sync_to_files',
    'write_backups',
    'auto_update',
    'premium_ui',
    'auto_prep',
    'energy_analysis',
    'watch_enabled',
  };

  void set(String key, Object? value) {
    String s() => value is String ? value : '';
    void choice(List<String> ok, String msg) {
      if (!ok.contains(s())) _bad(msg);
      cat.setSetting(key, s());
    }

    switch (key) {
      case 'low_bitrate_kbps':
        final v = value is int
            ? value
            : (value is double && value == value.truncateToDouble()
                  ? value.toInt()
                  : null);
        if (v == null || v < 0) _bad('threshold must be a whole number');
        if (v < 8 || v > 2000) {
          _bad('threshold must be between 8 and 2000 kbps');
        }
        cat.setSetting(key, '$v');
      case 'theme':
        choice(['dark', 'light'], 'theme must be dark or light');
      case 'surface':
        choice(['glass', 'solid'], 'unknown surface style');
      case 'motion':
        choice(['full', 'reduced'], 'unknown motion setting');
      case 'serato_dir':
        cat.setSetting(key, s().trim());
      case 'accent':
        choice([
          'mint',
          'cyan',
          'violet',
          'amber',
          'rose',
        ], 'accent must be mint, cyan, violet, amber or rose');
      case 'key_notation':
        choice([
          'camelot',
          'musical',
        ], 'key notation must be camelot or musical');
      case 'ui_prefs':
        if (value is! Map) _bad('ui_prefs must be an object');
        final text = jsonEncode(value);
        if (text.length > 4096) _bad('ui_prefs is too large');
        cat.setSetting(key, text);
      case final k when flags.contains(k):
        cat.setSetting(key, value == true ? '1' : '0');
      default:
        _bad('unknown setting');
    }
  }

  static const _keyed = {'spotify', 'youtube'};

  /// Every online service with its switch and whether a key is saved (the
  /// key itself never leaves the credential store).
  List<Map<String, Object?>> services() {
    return [
      for (final s in onlineServices)
        {
          'id': s.id,
          'name': s.name,
          'provides': s.gives,
          'sends': s.sends,
          'enabled': switch (s.id) {
            'updates' => _flag('auto_update', true),
            _ => serviceEnabled(cat, s.id),
          },
          'needs_key': _keyed.contains(s.id),
          'has_key': _keyed.contains(s.id) && secrets.get(s.id) != null,
        },
    ];
  }

  void setService(String svc, bool on) {
    if (!onlineServices.any((s) => s.id == svc)) _bad('unknown service');
    cat.setSetting(
      svc == 'updates' ? 'auto_update' : 'svc_$svc',
      on ? '1' : '0',
    );
  }

  void setSecret(String svc, String value) {
    if (!_keyed.contains(svc)) _bad('unknown service');
    if (svc == 'spotify' && !value.trim().contains(':')) {
      _bad('enter the Spotify Client ID and Client secret');
    }
    final v = value.trim();
    if (v.isEmpty ||
        v.length > 200 ||
        RegExp(r'[\s\x00-\x1f\x7f]').hasMatch(v)) {
      _bad('that does not look like an API key');
    }
    try {
      secrets.set(svc, v);
    } on OnlineException catch (e) {
      _bad(e.message);
    }
  }

  void deleteSecret(String svc) => secrets.delete(svc);

  /// Every setting back to its default, and every saved API key removed.
  /// The library, crates and music files are not touched.
  void resetAll() {
    for (final k in _keyed) {
      try {
        secrets.delete(k);
      } on Object {
        // not saved
      }
    }
    cat.db.execute('DELETE FROM settings');
  }
}
