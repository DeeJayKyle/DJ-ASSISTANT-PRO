/// Turns messy file names ("01_-_DJ_kozi-Sunset_Drive_(Original_Mix)_[FREE DL]_www.promo.net.mp3")
/// into "DJ Kozi - Sunset Drive (Original Mix)" (1.x `src/lib/quick/names.ts`).
/// Tags win when they look real; the file name fills the gaps. Deterministic
/// and local; the optional AI pass only refines it.
library;

class CleanName {
  const CleanName(this.artist, this.title, this.mix);
  final String artist, title;

  /// e.g. "Original Mix", "Extended Mix", "Joe Remix"
  final String mix;

  CleanName copyWith({String? artist, String? title, String? mix}) =>
      CleanName(artist ?? this.artist, title ?? this.title, mix ?? this.mix);

  Map<String, String> toJson() => {
    'artist': artist,
    'title': title,
    'mix': mix,
  };

  @override
  bool operator ==(Object other) =>
      other is CleanName &&
      other.artist == artist &&
      other.title == title &&
      other.mix == mix;
  @override
  int get hashCode => Object.hash(artist, title, mix);
  @override
  String toString() => 'CleanName($artist | $title | $mix)';
}

/// 'artist-title' or 'title-artist'.
typedef NameFormat = String;

const _upper = {
  'DJ',
  'MC',
  'VIP',
  'UK',
  'USA',
  'US',
  'NYC',
  'LA',
  'EDM',
  'DNB',
  'UKG',
  'II',
  'III',
  'IV',
  'XL',
  'TV',
  'AI',
  'OG',
  'R&B',
  'B2B',
  'BPM',
};
const _lower = {
  'a',
  'an',
  'and',
  'as',
  'at',
  'by',
  'for',
  'in',
  'of',
  'on',
  'or',
  'the',
  'to',
  'vs',
  'feat',
  'ft',
  'x',
  'de',
  'la',
  'le',
  'el',
  'y',
};
final _mixWords = RegExp(
  r'\b(clean|dirty|explicit|intro|original|extended|club|radio|dub|vip|instrumental|acapella|a cappella|vocal|remix|rework|edit|bootleg|flip|mix|version|remaster(ed)?|re-?edit|live)\b',
  caseSensitive: false,
);

/// Noise that download sites and promo pools add to names.
final _junk = <RegExp>[
  RegExp(
    r'\[(free\s*(dl|download)|out now|premiere|exclusive|promo|hq|hd|official( video| audio)?|lyrics?)[^\]]*\]',
    caseSensitive: false,
  ),
  RegExp(
    r'\((free\s*(dl|download)|out now|premiere|exclusive|promo|hq|hd|official( video| audio)?|lyrics?)[^)]*\)',
    caseSensitive: false,
  ),
  RegExp(r'\b(free\s*(dl|download)|out now|premiere)\b', caseSensitive: false),
  RegExp(
    r'\b(www\.)?[a-z0-9-]+\.(com|net|org|io|co|ru|me|fm|info|biz|to|cc)\b',
    caseSensitive: false,
  ),
  RegExp(r'\b\d{2,3}\s?kbps\b', caseSensitive: false),
  RegExp(r'\b(320|256|192|128)k?\b(?=\s*$|\s*\))', caseSensitive: false),
  RegExp(
    r'\b(final|copy|new|master(ed)?|mp3|wav|flac|aiff?)\b(?=(\s+(final|v\d+|copy|\d+))*\s*$)',
    caseSensitive: false,
  ),
  RegExp(r'\bv\d+\b\s*$', caseSensitive: false),
  RegExp(r'\(\d\)\s*$'),
];

String _tidy(String s) => s
    .replaceAll(RegExp(r'\s+'), ' ')
    .replaceAllMapped(RegExp(r'\s*([)\]])'), (m) => m[1]!)
    .replaceAllMapped(RegExp(r'([([])\s*'), (m) => m[1]!)
    .replaceAll(RegExp(r'^[\s\-–—_.,]+|[\s\-–—_.,]+$'), '')
    .trim();

/// JavaScript's `String.prototype.split` with a capturing separator: the
/// captured text is kept, and empty matches right after a split are skipped.
List<String> jsSplit(String s, RegExp sep) {
  final out = <String>[];
  if (s.isEmpty) return sep.matchAsPrefix(s) == null ? [s] : [];
  var p = 0, q = 0;
  while (q < s.length) {
    final m = sep.matchAsPrefix(s, q);
    if (m == null || m.end == p) {
      q++;
      continue;
    }
    out.add(s.substring(p, q));
    for (var g = 1; g <= m.groupCount; g++) {
      out.add(m[g] ?? '');
    }
    p = m.end;
    q = p;
  }
  out.add(s.substring(p));
  return out;
}

final _caseSep = RegExp(r'(\s+|(?=[-/&()])|(?<=[-/&(]))');

/// Title-cases words that are all lower or all upper case; leaves mixed-case
/// words ("deadmau5", "SebastiAn") alone.
String smartCase(String s) {
  final parts = jsSplit(s, _caseSep);
  final out = StringBuffer();
  for (var i = 0; i < parts.length; i++) {
    final w = parts[i];
    if (w.trim().isEmpty || RegExp(r'^[-/&()]$').hasMatch(w)) {
      out.write(w);
      continue;
    }
    final bare = w.replaceAll(RegExp('[^A-Za-z&]'), '');
    if (_upper.contains(bare.toUpperCase())) {
      out.write(w.replaceFirst(bare, bare.toUpperCase()));
      continue;
    }
    // Mixed case ("SebastiAn") or letters with digits ("deadmau5") are styled on purpose.
    final styled =
        (RegExp('[a-z]').hasMatch(w) && RegExp('[A-Z]').hasMatch(w)) ||
        (RegExp('[a-z]', caseSensitive: false).hasMatch(w) &&
            RegExp(r'\d').hasMatch(w));
    if (styled) {
      out.write(w);
      continue;
    }
    final low = w.toLowerCase();
    if (i > 0 && _lower.contains(low.replaceAll('.', ''))) {
      out.write(low);
      continue;
    }
    out.write(
      low.replaceAllMapped(
        RegExp("(^|[^a-z'’])([a-z])"),
        (m) => '${m[1]}${m[2]!.toUpperCase()}',
      ),
    );
  }
  return out.toString();
}

String _stripJunk(String s) {
  var t = s;
  for (final re in _junk) {
    t = t.replaceAll(re, ' ');
  }
  return t.replaceAll(RegExp(r'\[\s*\]|\(\s*\)'), ' ');
}

/// Pulls "(Original Mix)", "[Joe Remix]" or a trailing "Extended Mix" out of a title.
(String, String) _splitMix(String title) {
  final bracket = RegExp(r'[([]([^)\]]+)[)\]]\s*$').firstMatch(title);
  if (bracket != null && _mixWords.hasMatch(bracket[1]!)) {
    return (_tidy(title.substring(0, bracket.start)), _tidy(bracket[1]!));
  }
  final trailing = RegExp(
    r'\s[-–]\s([^-–]+(?:mix|edit|remix|dub|rework|version))\s*$',
    caseSensitive: false,
  ).firstMatch(title);
  if (trailing != null) {
    return (_tidy(title.substring(0, trailing.start)), _tidy(trailing[1]!));
  }
  return (_tidy(title), '');
}

CleanName parseFileName(String fileName) {
  var base = fileName.replaceFirst(
    RegExp(r'\.[a-z0-9]{2,5}$', caseSensitive: false),
    '',
  );
  // "name__clean_" is what "name (clean)" becomes when a site swaps brackets for underscores.
  base = base.replaceFirstMapped(
    RegExp(r'__([a-z0-9][a-z0-9 _-]*?)_$', caseSensitive: false),
    (m) => ' (${m[1]!.replaceAll('_', ' ')})',
  );
  base = base.replaceAll('_-_', ' - ').replaceAll('_', ' ');
  base = _stripJunk(base);
  // Leading track numbers: "01 ", "01. ", "A1 ", "1-03 "
  base = base.replaceFirst(
    RegExp(r'^\s*(\d{1,3}[\s.\-)_]+|[A-D]\d{1,2}\s+|\d-\d{2}\s+)'),
    '',
  );
  base = _tidy(base);
  var parts = base.split(RegExp(r'\s+[-–—]\s+'));
  if (parts.length == 1) parts = base.split(RegExp(r'\s*[-–—]\s*(?=[A-Za-z])'));
  var artist = '';
  var title = base;
  if (parts.length >= 2) {
    artist = parts[0];
    title = parts.sublist(1).join(' - ');
  }
  final (t, mix) = _splitMix(title);
  artist = smartCase(_tidy(artist));
  title = smartCase(t);
  // Placeholder names ("track02", "audio 3") become a readable "Track 02".
  title = title.replaceFirstMapped(
    RegExp(r'^(track|audio|untitled|song)\s*(\d+)$', caseSensitive: false),
    (m) =>
        '${m[1]![0].toUpperCase()}${m[1]!.substring(1).toLowerCase()} ${m[2]}',
  );
  return CleanName(artist, title, mix.isNotEmpty ? smartCase(mix) : '');
}

bool _looksReal(String? s) =>
    s != null &&
    s.trim().isNotEmpty &&
    !RegExp(
      r'^(track|audio|untitled)\s*\d*$',
      caseSensitive: false,
    ).hasMatch(s.trim()) &&
    !RegExp(r'^\d+$').hasMatch(s.trim());

/// Combines tags and the file name: real tags win, the file name fills gaps.
CleanName cleanName(String fileName, {String? artist, String? title}) {
  final fromFile = parseFileName(fileName);
  final tagTitle = _looksReal(title) ? title!.trim() : '';
  final tagArtist = _looksReal(artist) ? artist!.trim() : '';
  final a = tagArtist.isNotEmpty
      ? smartCase(_tidy(_stripJunk(tagArtist)))
      : fromFile.artist;
  if (tagTitle.isEmpty) return fromFile.copyWith(artist: a);
  final (t, mix) = _splitMix(_tidy(_stripJunk(tagTitle)));
  return CleanName(
    a,
    smartCase(t),
    mix.isNotEmpty ? smartCase(mix) : fromFile.mix,
  );
}

String formatName(CleanName n, [NameFormat format = 'artist-title']) {
  final main = n.artist.isEmpty
      ? n.title
      : format == 'artist-title'
      ? '${n.artist} - ${n.title}'
      : '${n.title} - ${n.artist}';
  return n.mix.isNotEmpty ? '$main (${n.mix})' : main;
}

/// A name every OS accepts as a file name (no \ / : * ? " < > |, no trailing dots, sane length).
String safeFileName(String name, [int maxLength = 150]) {
  var s = name
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .replaceFirst(RegExp(r'[. ]+$'), '');
  if (RegExp(
    r'^(con|prn|aux|nul|com\d|lpt\d)$',
    caseSensitive: false,
  ).hasMatch(s)) {
    s = '${s}_';
  }
  if (s.length > maxLength) s = s.substring(0, maxLength).trim();
  return s.isEmpty ? 'Untitled' : s;
}

/// Whether a file still needs its name cleaning.
bool needsCleanup(
  String fileName,
  CleanName n, [
  NameFormat format = 'artist-title',
]) =>
    fileName.replaceFirst(
      RegExp(r'\.[a-z0-9]{2,5}$', caseSensitive: false),
      '',
    ) !=
    safeFileName(formatName(n, format));
