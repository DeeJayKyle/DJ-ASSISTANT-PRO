import 'dart:convert';

import '../assistant/ai_config.dart';
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
      'chat_open': _flag('chat_open', true),
      'privacy_acknowledged': _flag('privacy_acknowledged', false),
      'allow_file_changes': _flag('allow_file_changes', false),
      'docs_enabled': _flag('docs_enabled', false),
      'watch_enabled': _flag('watch_enabled', false),
      'learning_enabled': _flag('learning_enabled', true),
      'gig_mode': _flag('gig_mode', false),
      'auto_update': _flag('auto_update', true),
      'surface': cat.getSetting('surface') ?? 'glass',
      'motion': cat.getSetting('motion') ?? 'full',
      'accent': cat.getSetting('accent') ?? 'mint',
      'key_notation': cat.getSetting('key_notation') ?? 'camelot',
      'scan_video': _flag('scan_video', true),
      'ai_gpu': _flag('ai_gpu', true),
      'studio_cores': int.tryParse(cat.getSetting('studio_cores') ?? '') ?? 0,
      'audio_buffer_ms':
          int.tryParse(cat.getSetting('audio_buffer_ms') ?? '') ?? 120,
      'premium_ui': _flag('premium_ui', false),
      'auto_prep': autoPrepEnabled(cat),
      'ui_prefs': prefs is Map ? prefs : <String, Object?>{},
      'auto_fix_min': autoFixMin(cat),
      'ai_provider': cat.getSetting('ai_provider') ?? 'off',
    };
  }

  Never _bad(String m) => throw SettingsException(m);

  static const flags = {
    'chat_open',
    'privacy_acknowledged',
    'allow_file_changes',
    'docs_enabled',
    'learning_enabled',
    'auto_update',
    'scan_video',
    'ai_gpu',
    'premium_ui',
    'auto_prep',
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
      case 'studio_cores':
        // 0: automatic (every core but one)
        final v = value is num ? value.toInt() : int.tryParse('$value');
        if (v == null || v < 0) _bad('cores must be 0 (automatic) or more');
        cat.setSetting(key, '$v');
      case 'audio_buffer_ms':
        final v = value is num ? value.toInt() : int.tryParse('$value');
        if (v == null || v < 10) {
          _bad('the audio buffer must be at least 10 ms');
        }
        cat.setSetting(key, '$v');
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
      case 'auto_fix_min':
        final v = value is num ? value.toDouble() : null;
        if (v == null || v < 0.5 || v > 1.0) {
          _bad('confidence must be between 0.5 and 1.0');
        }
        cat.setSetting(key, '$v');
      case 'ai_provider':
        if (!isProvider(s())) _bad('unknown AI provider');
        cat.setSetting(key, s());
        // remembered so the Online services switch turns the same one back on
        if (s() != 'off' && s() != 'local') {
          cat.setSetting('ai_online_last', s());
        }
      case 'ai_custom_url':
        final v = s().trim().replaceAll(RegExp(r'/+$'), '');
        if (!validCustomUrl(v)) {
          _bad(
            'enter an https:// address, or http:// on this computer (e.g. http://127.0.0.1:1234/v1)',
          );
        }
        cat.setSetting(key, v);
      case 'ai_model':
        if (!claudeModels.any((m) => m.$1 == s())) _bad('unknown Claude model');
        cat.setSetting(key, s());
      case 'ai_local_model':
        final v = s().trim();
        if (v.isEmpty ||
            v.length > 100 ||
            !RegExp(r'^[A-Za-z0-9:._\-/]+$').hasMatch(v)) {
          _bad("that doesn't look like a model name (e.g. qwen2.5:7b)");
        }
        cat.setSetting(key, v);
      case 'ai_local_url':
        final v = s().trim().replaceAll(RegExp(r'/+$'), '');
        // Local means local: only this computer's model server.
        final ok = ['http://127.0.0.1:', 'http://localhost:', 'http://[::1]:']
            .any(
              (p) =>
                  v.startsWith(p) &&
                  v.length > p.length &&
                  RegExp(r'^\d+$').hasMatch(v.substring(p.length)),
            );
        if (!ok) {
          _bad(
            'the local model server must be on this computer, e.g. http://127.0.0.1:11434',
          );
        }
        cat.setSetting(key, v);
      case final k
          when k.startsWith('ai_model_') && aiService(k.substring(9)) != null:
        final v = s().trim();
        if (!validModelName(v)) {
          _bad("that doesn't look like a model name (e.g. gpt-4.1-mini)");
        }
        cat.setSetting(key, v);
      case final k when flags.contains(k):
        cat.setSetting(key, value == true ? '1' : '0');
      default:
        _bad('unknown setting');
    }
  }

  static const _keyed = {
    'acoustid',
    'lastfm',
    'anthropic',
    'spotify',
    'getsongbpm',
    'youtube',
  };

  /// Every online service with its switch and whether a key is saved (the
  /// key itself never leaves the credential store).
  List<Map<String, Object?>> services() {
    final provider = cat.getSetting('ai_provider');
    return [
      for (final s in onlineServices)
        {
          'id': s.id,
          'name': s.name,
          'provides': s.gives,
          'sends': s.sends,
          'enabled': switch (s.id) {
            'updates' => _flag('auto_update', true),
            'anthropic' =>
              provider != null && provider != 'off' && provider != 'local',
            _ => serviceEnabled(cat, s.id),
          },
          'needs_key': _keyed.contains(s.id),
          'has_key': _keyed.contains(s.id) && secrets.get(s.id) != null,
        },
    ];
  }

  void setService(String svc, bool on) {
    if (!onlineServices.any((s) => s.id == svc)) _bad('unknown service');
    if (svc == 'anthropic') {
      final last = cat.getSetting('ai_online_last');
      cat.setSetting(
        'ai_provider',
        on ? ((last != null && isProvider(last)) ? last : 'claude') : 'off',
      );
      return;
    }
    cat.setSetting(
      svc == 'updates' ? 'auto_update' : 'svc_$svc',
      on ? '1' : '0',
    );
  }

  void setSecret(String svc, String value) {
    final aiKey = svc.startsWith('ai_') && aiService(svc.substring(3)) != null;
    if (!_keyed.contains(svc) && !aiKey) _bad('unknown service');
    if (svc == 'spotify' && !value.trim().contains(':')) {
      _bad('enter the Spotify Client ID and Client secret');
    }
    if (svc == 'anthropic' && !value.trim().startsWith('sk-ant-')) {
      _bad('Anthropic API keys start with sk-ant-');
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
}
