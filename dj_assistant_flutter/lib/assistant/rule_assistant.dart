import '../core/catalogue.dart';
import '../core/json.dart';
import '../core/keys.dart';
import '../core/library.dart';
import '../core/library_edit.dart';
import '../core/rules.dart';
import '../core/suggestions.dart';
import '../core/text.dart';

/// The built-in helper used while the AI assistant is off (1.x
/// `assistant.rs`). It is NOT an AI model: it recognises a fixed set of
/// phrases, turns them into the filters the Library uses, and says exactly
/// what it understood. It never changes files.
class AssistantReply {
  AssistantReply({
    required this.reply,
    required this.action,
    this.understood = const [],
    this.target,
    this.text,
    this.filters,
    this.total,
    this.sample = const [],
    this.params,
  });
  final String reply, action; // action: search | navigate | help
  final List<String> understood;
  final String? target, text;
  final Map<String, Object?>? filters, params;
  final int? total;
  final List<TrackRow> sample;

  Map<String, Object?> toJson() => {
    'reply': reply,
    'understood': understood,
    'action': action,
    'target': target,
    'text': text,
    'filters': filters,
    'total': total,
    'sample': [for (final t in sample) t.toJson()],
    'params': ?params,
  };
}

const assistantHelp =
    "I'm a local, rule-based helper (not an AI model). I can turn requests like these into library filters:\n"
    '• "afrobeats from the 2010s energy 6-8 no live"\n'
    '• "house 120-128 bpm"  • "key 8A"  • "clean 90s hip hop"\n'
    '• "low bitrate"  • "lossless"  • "missing genre"\n'
    '• "show duplicates"  • "library health"  • "scan"\n'
    '• "plan a 2 hour wedding set"  • "gig mode"  • "gig pack"  • "suggestions"\n'
    "Everything stays on this computer. I can't edit files, tags or Serato data.";

Map<String, Object?> _cond(String field, String op, Object? value) => {
  'kind': 'condition',
  'field': field,
  'op': op,
  'value': value,
};

/// Rust's `str::parse::<f64>` (digits, sign, point, exponent; inf/nan words).
double? _f64(String s) {
  if (!RegExp(
    r'^[+-]?((\d+\.?\d*|\.\d+)([eE][+-]?\d+)?|inf|infinity|nan)$',
    caseSensitive: false,
  ).hasMatch(s)) {
    return null;
  }
  final l = s.toLowerCase().replaceFirst('+', '');
  if (l.endsWith('inf') || l.endsWith('infinity')) {
    return l.startsWith('-') ? double.negativeInfinity : double.infinity;
  }
  if (l.endsWith('nan')) return double.nan;
  return double.parse(s);
}

int? _i64(String s) => RegExp(r'^[+-]?\d+$').hasMatch(s)
    ? int.tryParse(s.replaceFirst('+', ''))
    : null;

(double, double)? _range(String raw) {
  final s = raw.replaceAll('–', '-');
  final i = s.indexOf('-');
  if (i >= 0) {
    final a = _f64(s.substring(0, i).trim()),
        b = _f64(s.substring(i + 1).trim());
    if (a == null || b == null) return null;
    return (a < b ? a : b, a < b ? b : a);
  }
  final v = _f64(s.trim());
  return v == null ? null : (v, v);
}

String _trimEnd(String s, String suffix) {
  var t = s;
  while (suffix.isNotEmpty && t.endsWith(suffix)) {
    t = t.substring(0, t.length - suffix.length);
  }
  return t;
}

String _trimStart(String s, String prefix) {
  var t = s;
  while (prefix.isNotEmpty && t.startsWith(prefix)) {
    t = t.substring(prefix.length);
  }
  return t;
}

int? _decadeOf(String tok) {
  final t = _trimStart(_trimEnd(_trimEnd(tok, "'s"), 's'), "'");
  if (!tok.endsWith('s') || !RegExp(r'^[0-9]*$').hasMatch(t)) return null;
  if (t.length == 4) {
    final y = int.parse(t);
    return (y % 10 == 0 && y >= 1900 && y < 2100) ? y : null;
  }
  if (t.length == 2) {
    final y = int.parse(t);
    return y % 10 == 0 ? (y >= 30 ? 1900 + y : 2000 + y) : null;
  }
  return null;
}

bool _sharpFlatMinor(String t) =>
    t.length == 3 &&
    RegExp('[a-g]').hasMatch(t[0]) &&
    (t[1] == '#' || t[1] == 'b') &&
    t[2] == 'm';

bool _camelot(String t) {
  if (t.isEmpty) return false;
  final u = t.toUpperCase();
  final l = u.substring(u.length - 1), n = u.substring(0, u.length - 1);
  if (l != 'A' && l != 'B') return false;
  final v = RegExp(r'^\+?\d+$').hasMatch(n)
      ? int.tryParse(n.replaceFirst('+', ''))
      : null;
  return v != null && v >= 1 && v <= 12;
}

String _n(double v) => rustNumber(v);

AssistantReply _nav(String target, String reply) =>
    AssistantReply(reply: reply, action: 'navigate', target: target);

AssistantReply ruleAssistant(Catalogue cat, String message) {
  final msg = fold(message.trim());
  final understood = <String>[];
  if (msg.isEmpty ||
      ['help', '?', 'what can you do', 'hi', 'hello', 'hey'].contains(msg)) {
    return AssistantReply(reply: assistantHelp, action: 'help');
  }
  // Set planning: "plan a 2 hour wedding set", "90 minute warm up set"
  if (msg.contains(' set') &&
      (msg.contains('plan') ||
          msg.contains('build') ||
          msg.contains('make') ||
          msg.contains('hour') ||
          msg.contains('minute') ||
          msg.contains('min '))) {
    final words = msg.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    int? minutes;
    for (var i = 0; i + 1 < words.length; i++) {
      final n = _f64(words[i]);
      if (n == null) continue;
      final w = words[i + 1];
      if (w.startsWith('hour') || w == 'h' || w == 'hr' || w == 'hrs') {
        minutes = _sat(n * 60);
      } else if (w.startsWith('min')) {
        minutes = _sat(n);
      }
    }
    final event = [
      'wedding',
      'club',
      'festival',
      'corporate',
      'birthday',
      'lounge',
      'house party',
      'private party',
      'latin night',
    ].where(msg.contains).firstOrNull;
    final curve = msg.contains('warm')
        ? 'warmup'
        : msg.contains('peak')
        ? 'peak'
        : msg.contains('wedding')
        ? 'wedding'
        : (msg.contains('lounge') || msg.contains('chill'))
        ? 'lounge'
        : 'journey';
    final clean = msg.contains('clean');
    return AssistantReply(
      reply: 'Opening Set Studio with these settings. Review them and press Generate — the plan is a suggestion you can edit.',
      action: 'navigate',
      target: 'set-studio',
      understood: [
        'length ${minutes ?? 60} min',
        'energy journey: $curve',
        if (event != null) 'event: $event',
        if (clean) 'clean tracks only',
      ],
      params: {
        'duration_min': minutes ?? 60,
        'event_type': event,
        'curve': curve,
        'clean_only': clean,
      },
    );
  }
  for (final (words, target, reply) in [
    (
      ['gig mode', 'start gig', 'start a gig', 'requests'],
      'gig',
      'Opening Gig Mode: set list, requests and notes, with background work paused.',
    ),
    (
      ['gig pack', 'usb', 'copy to drive', 'pack'],
      'gig-pack',
      'Opening Gig Pack: choose tracks and a drive; copies are verified and nothing is overwritten.',
    ),
    (
      ['suggestion', 'fix tags', 'metadata', 'musicbrainz'],
      'suggestions',
      'Opening Suggestions: review each one before it reaches your catalogue.',
    ),
    (
      ['discover', 'recommend', 'similar', 'tracklist', 'gaps'],
      'discovery',
      'Opening Discovery: recommendations always show their reason and source.',
    ),
    (
      ['analyse', 'analyze', 'analysis', 'detect bpm', 'detect key'],
      'activity',
      'Opening Scan & Analysis. Analysis reads your files and stores estimates you can override.',
    ),
    (
      ['template', 'cheat sheet', 'organise crates', 'organize crates'],
      'crates',
      'Opening Virtual Crates, where you can add crate templates (genre, energy, utility, events, ratings).',
    ),
    (
      ['personal files', 'documents'],
      'files',
      'Opening Personal Files (opt-in, separate from music).',
    ),
    (['update'], 'settings', 'Opening Settings → Updates.'),
  ]) {
    if (words.any(msg.contains)) return _nav(target, reply);
  }
  if (msg.contains('duplicate') || msg.contains('dupes')) {
    return _nav(
      'duplicates',
      'Opening Duplicate review. Exact matches (identical file contents) are shown separately from possible matches and alternate versions. Nothing is deleted.',
    );
  }
  if (['health', 'problems', 'errors', 'corrupt'].any(msg.contains)) {
    return _nav(
      'health',
      'Opening Library health: missing metadata, unreadable files, low-bitrate warnings, offline drives and missing files.',
    );
  }
  if (msg == 'scan' ||
      msg.startsWith('scan ') ||
      msg.startsWith('rescan') ||
      msg.contains('add folder')) {
    return _nav(
      'activity',
      'Opening Scan & Analysis. Choose a folder to add, then press Scan. Scanning only reads your files.',
    );
  }

  final rules = <Map<String, Object?>>[], exclude = <Map<String, Object?>>[];
  final words = <String>[];
  final raw = msg
      .replaceAll(',', ' ')
      .split(RegExp(r'\s+'))
      .where((s) => s.isNotEmpty)
      .toList();
  // Merge "120 to 128" into "120-128" (numbers only, so titles stay intact).
  final toks = <String>[];
  for (var k = 0; k < raw.length;) {
    if (k + 2 < raw.length &&
        raw[k + 1] == 'to' &&
        _f64(raw[k]) != null &&
        _f64(raw[k + 2]) != null) {
      toks.add('${raw[k]}-${raw[k + 2]}');
      k += 3;
    } else {
      toks.add(raw[k]);
      k++;
    }
  }
  const stop = {
    'show',
    'me',
    'find',
    'list',
    'tracks',
    'songs',
    'music',
    'with',
    'from',
    'the',
    'in',
    'of',
    'and',
    'some',
    'all',
    'my',
    'a',
    'for',
    'era',
    'please',
    'that',
    'are',
    'is',
    'only',
  };
  var negate = false;
  for (var i = 0; i < toks.length;) {
    final t = toks[i];
    final next = i + 1 < toks.length ? toks[i + 1] : null;
    if ([
      'no',
      'not',
      'without',
      'exclude',
      'excluding',
      'except',
      'minus',
    ].contains(t)) {
      negate = true;
      i++;
      continue;
    }
    void push(Map<String, Object?> node, bool neg) =>
        neg ? exclude.add(node) : rules.add(node);
    const versions = {
      'live',
      'remix',
      'edit',
      'acapella',
      'instrumental',
      'extended',
      'intro',
      'dub',
      'bootleg',
      'mashup',
    };
    final vw = _trimEnd(t, 's');
    if (versions.contains(vw)) {
      push(_cond('version', 'contains', vw), negate);
      understood.add(
        '${negate ? 'excluding' : 'with'} version label contains "$vw"',
      );
      negate = false;
      i++;
      continue;
    }
    if (t == 'clean' || t == 'explicit' || t == 'dirty') {
      final v = t == 'clean' ? 'clean' : 'explicit';
      if (negate) {
        exclude.add(_cond('clean_explicit', 'equals', v));
        understood.add('excluding tracks marked $v');
      } else {
        rules.add(_cond('clean_explicit', 'equals', v));
        understood.add('marked $v (from your catalogue or the title)');
      }
      negate = false;
      i++;
      continue;
    }
    if (_decadeOf(t) case final d?) {
      rules.add(_cond('decade', 'eq', d));
      understood.add('decade ${d}s');
      i++;
      continue;
    }
    if (t == 'bpm' && next != null) {
      if (_range(next) case (final a, final b)) {
        rules.add(_cond('bpm', 'between', [a, b]));
        understood.add('BPM ${_n(a)}–${_n(b)}');
        i += 2;
        continue;
      }
    }
    if (next == 'bpm') {
      if (_range(t) case (final a, final b)) {
        rules.add(_cond('bpm', 'between', [a, b]));
        understood.add('BPM ${_n(a)}–${_n(b)}');
        i += 2;
        continue;
      }
    }
    if (t == 'energy' && next != null) {
      if (_range(next) case (final a, final b)) {
        rules.add(_cond('energy', 'between', [a, b]));
        understood.add('energy ${_n(a)}–${_n(b)}');
        i += 2;
        continue;
      }
    }
    if ((t == 'high' || t == 'low' || t == 'medium') && next == 'energy') {
      final (a, b) = switch (t) {
        'high' => (7, 10),
        'low' => (1, 4),
        _ => (5, 6),
      };
      rules.add(_cond('energy', 'between', [a, b]));
      understood.add('$t energy ($a–$b, from your ratings)');
      i += 2;
      continue;
    }
    if ((t == 'low' && next == 'bitrate') || t == 'low-bitrate') {
      rules.add(_cond('quality', 'equals', 'low_bitrate'));
      understood.add('low-bitrate lossy files');
      i += t == 'low' ? 2 : 1;
      continue;
    }
    if (['video', 'videos', 'clip', 'clips', 'visuals'].contains(t) ||
        (t == 'music' && (next?.startsWith('video') ?? false))) {
      rules.add(_cond('media', 'equals', 'video'));
      understood.add('video files');
      i += t == 'music' ? 2 : 1;
      continue;
    }
    if (t == 'audio' && next == 'only') {
      rules.add(_cond('media', 'equals', 'audio'));
      understood.add('audio files only');
      i += 2;
      continue;
    }
    final h = switch (t) {
      '4k' || '2160p' || 'uhd' => 2000,
      '1080p' || 'fullhd' || 'fhd' => 1080,
      'hd' || '720p' => 720,
      _ => null,
    };
    if (h != null) {
      rules
        ..add(_cond('media', 'equals', 'video'))
        ..add(_cond('video_height', 'gte', h));
      understood.add('video ${h}p or better');
      i++;
      continue;
    }
    if (t == 'lossless') {
      rules.add(_cond('quality', 'equals', 'lossless'));
      understood.add('lossless files');
      i++;
      continue;
    }
    if ((t == 'missing' || t == 'no-genre') &&
        ['genre', 'year', 'artist', 'title', 'bpm', 'key'].contains(next)) {
      rules.add(_cond(next!, 'is_empty', null));
      understood.add('$next is unknown');
      i += 2;
      continue;
    }
    if (t == 'key' && next != null) {
      // "key 8A", "key Am", "key F#m", "key A minor", "key 1m"
      final after = i + 2 < toks.length ? toks[i + 2] : null;
      final q = ['minor', 'major', 'min', 'maj'].contains(after);
      final c = normalizeKey(q ? '$next $after' : next);
      if (c != null) {
        rules.add(_cond('key', 'equals', c));
        understood.add('key $c');
        i += q ? 3 : 2;
        continue;
      }
    }
    if (_camelot(t) || _sharpFlatMinor(t)) {
      if (normalizeKey(t) case final c?) {
        rules.add(_cond('key', 'equals', c));
        understood.add('key $c');
        i++;
        continue;
      }
    }
    if (t.contains('-')) {
      if (_range(t) case (final a, final b)
          when a >= 1900 && a < 2100 && b >= 1900 && b < 2100) {
        rules.add(_cond('year', 'between', [a, b]));
        understood.add('year ${_n(a)}–${_n(b)}');
        i++;
        continue;
      }
    }
    if (t.length == 4 && RegExp(r'^[0-9]{4}$').hasMatch(t)) {
      final y = int.parse(t);
      if (y >= 1900 && y < 2100) {
        rules.add(_cond('year', 'eq', y));
        understood.add('year $y');
        i++;
        continue;
      }
    }
    if (t.endsWith('star') ||
        t.endsWith('stars') ||
        ((next?.startsWith('star') ?? false) && _i64(t) != null)) {
      final n = _i64(_trimEnd(_trimEnd(_trimEnd(t, 'stars'), 'star'), '+'));
      if (n != null && n >= 0 && n <= 5) {
        rules.add(_cond('rating', 'gte', n));
        understood.add('rated $n+ stars');
        i += _i64(t) != null ? 2 : 1;
        continue;
      }
    }
    if (!stop.contains(t)) {
      if (negate) {
        exclude.add({
          'kind': 'group',
          'match': 'any',
          'rules': [
            _cond('genre', 'contains', t),
            _cond('title', 'contains', t),
            _cond('artist', 'contains', t),
          ],
        });
        understood.add('excluding "$t" in genre, title or artist');
        negate = false;
      } else {
        words.add(t);
      }
    }
    i++;
  }

  // Leading words that match a genre in the library become a genre rule.
  final lib = LibraryService(cat);
  final genres = lib.facet('genre', limit: 500);
  final free = <String>[];
  for (var gi = 0; gi < words.length;) {
    var matched = false;
    for (var len = 3; len >= 1; len--) {
      if (gi + len > words.length) continue;
      final phrase = words.sublist(gi, gi + len).join(' ');
      final alt = phrase.replaceAll(' ', '');
      final g = genres.where((g) {
        final fg = fold(g.$1);
        return fg == phrase || fg.replaceAll(RegExp('[ -]'), '') == alt;
      }).firstOrNull;
      if (g != null) {
        rules.add(_cond('genre', 'equals', g.$1));
        understood.add('genre "${g.$1}"');
        gi += len;
        matched = true;
        break;
      }
    }
    if (!matched) free.add(words[gi++]);
  }
  final text = free.isEmpty ? null : free.join(' ');
  if (text != null) {
    understood.add(
      'text "$text" anywhere in title, artist, album, genre, label, file name or tags',
    );
  }
  final filters = <String, Object?>{
    'match': 'all',
    'rules': rules,
    'exclude': exclude,
  };
  final page = lib.search(
    TrackQuery(
      text: text,
      limit: 8,
      extraWhere: compileRules(filters, lib.lowBitrateKbps),
    ),
  );
  final reply = understood.isEmpty
      ? "I didn't recognise any filters in that. Type \"help\" to see what I understand."
      : page.total == 0
      ? "No tracks match. Unknown values (for example energy you haven't rated yet) never count as a match."
      : "Found ${page.total} track${page.total == 1 ? '' : 's'}. I've applied these filters to the library view.";
  return AssistantReply(
    reply: reply,
    action: 'search',
    understood: understood,
    text: text,
    filters: filters,
    total: page.total,
    sample: page.rows,
  );
}

/// Rust's saturating `f64 as u32`.
int _sat(double v) {
  if (v.isNaN || v <= 0) return 0;
  if (v >= 4294967295) return 4294967295;
  return v.floor();
}
