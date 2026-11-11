import 'dart:io';

import 'package:path/path.dart' as p;

import 'catalogue.dart';
import 'library.dart';
import 'tags.dart';
import 'track_match.dart';

/// What bitrate can and can't tell you, shown wherever upgrades are offered.
const bitrateCaveat =
    'Bitrate is a clue, not proof of quality: a 320 kbps or lossless file can '
    'be a re-encoded low-quality copy, and a well-made 128 kbps file can sound '
    'fine in a club. Listen to both before you replace anything.';

/// Facts about one audio file, from the catalogue or read from the file's
/// headers (never written).
class AudioFacts {
  const AudioFacts({
    required this.path,
    this.format,
    this.codec,
    this.lossless,
    this.bitrateKbps,
    this.sampleRate,
    this.bitDepth,
    this.channels,
    this.durationMs,
    this.sizeBytes,
    this.lufs,
    this.peakDbfs,
    this.clippedRuns,
    this.trackId,
  });
  final String path;
  final String? format, codec;
  final bool? lossless;
  final int? bitrateKbps, sampleRate, bitDepth, channels, durationMs;
  final int? sizeBytes, clippedRuns, trackId;
  final double? lufs, peakDbfs;

  Map<String, Object?> toJson() => {
    'path': path,
    'format': format,
    'codec': codec,
    'lossless': lossless,
    'bitrate_kbps': bitrateKbps,
    'sample_rate': sampleRate,
    'bit_depth': bitDepth,
    'channels': channels,
    'duration_ms': durationMs,
    'size_bytes': sizeBytes,
    'lufs': lufs,
    'peak_dbfs': peakDbfs,
    'clipped_runs': clippedRuns,
    'track_id': trackId,
  };
}

/// A copy of the same song already in the library.
class OwnedAlternative {
  const OwnedAlternative(this.facts, this.reasons, this.lengthDiffSec);
  final AudioFacts facts;

  /// Why it may be better ("lossless", "320 kbps"); empty when it isn't.
  final List<String> reasons;
  final double? lengthDiffSec;
}

/// Low-bitrate tracks and their possible upgrades: copies you already own,
/// legitimate store searches (links only), and a side-by-side comparison to
/// listen to before replacing anything through Organise Files.
class UpgradeService {
  UpgradeService(this.cat);
  final Catalogue cat;

  void _ensure() => cat.db.execute(
    'CREATE TABLE IF NOT EXISTS upgrade_reviews (track_id INTEGER PRIMARY KEY, '
    "decision TEXT NOT NULL CHECK (decision IN ('keep')), at INTEGER NOT NULL)",
  );

  int get threshold => LibraryService(cat).lowBitrateKbps;

  /// Lossy audio tracks below the low-bitrate threshold, lowest first.
  /// Lossless and unknown-bitrate files are never listed. Tracks marked
  /// "keep as it is" are left out unless [includeKept].
  List<int> lowBitrateIds({bool includeKept = false, int? limit}) {
    _ensure();
    return [
      for (final r in cat.db.select(
        "SELECT t.id FROM tracks t WHERE t.presence='present' AND t.removed_at IS NULL "
        "AND t.media_kind='audio' AND t.lossless=0 AND t.bitrate_kbps IS NOT NULL AND t.bitrate_kbps < ? "
        '${includeKept ? '' : 'AND t.id NOT IN (SELECT track_id FROM upgrade_reviews)'} '
        'ORDER BY t.bitrate_kbps, t.id${limit == null ? '' : ' LIMIT $limit'}',
        [threshold],
      ))
        r['id'] as int,
    ];
  }

  int keptCount() {
    _ensure();
    return cat.db.select('SELECT COUNT(*) AS n FROM upgrade_reviews').first['n']
        as int;
  }

  Set<int> keptIds() {
    _ensure();
    return {
      for (final r in cat.db.select('SELECT track_id FROM upgrade_reviews'))
        r['track_id'] as int,
    };
  }

  /// "Keep as it is": the DJ listened and is happy; it stops being listed.
  void keep(int trackId) {
    _ensure();
    cat.db.execute(
      "INSERT OR REPLACE INTO upgrade_reviews(track_id, decision, at) VALUES (?, 'keep', ?)",
      [trackId, nowMs()],
    );
  }

  void unkeep(int trackId) {
    _ensure();
    cat.db.execute('DELETE FROM upgrade_reviews WHERE track_id=?', [trackId]);
  }

  /// Facts for a library track.
  AudioFacts trackFacts(int id) {
    final rows = cat.db.select(
      'SELECT t.id, t.path, t.format, t.codec, t.lossless, t.bitrate_kbps, t.sample_rate, t.bit_depth, '
      't.channels, t.duration_ms, t.file_size, a.loudness_lufs, a.peak_dbfs, a.clipped_runs '
      'FROM tracks t LEFT JOIN analysis a ON a.track_id=t.id WHERE t.id=?',
      [id],
    );
    if (rows.isEmpty) throw StateError('track not found');
    final r = rows.first;
    final lossless = r['lossless'] as int?;
    return AudioFacts(
      trackId: id,
      path: r['path'] as String,
      format: r['format'] as String?,
      codec: r['codec'] as String?,
      lossless: lossless == null ? null : lossless == 1,
      bitrateKbps: r['bitrate_kbps'] as int?,
      sampleRate: r['sample_rate'] as int?,
      bitDepth: r['bit_depth'] as int?,
      channels: r['channels'] as int?,
      durationMs: r['duration_ms'] as int?,
      sizeBytes: r['file_size'] as int?,
      lufs: (r['loudness_lufs'] as num?)?.toDouble(),
      peakDbfs: (r['peak_dbfs'] as num?)?.toDouble(),
      clippedRuns: r['clipped_runs'] as int?,
    );
  }

  /// Facts for any audio file (a new purchase, say), read from its headers
  /// only. A file already in the library uses its catalogue entry, which
  /// includes loudness when it has been analysed.
  AudioFacts fileFacts(String path) {
    final known = cat.db.select(
      "SELECT id FROM tracks WHERE path=? AND removed_at IS NULL",
      [path],
    );
    if (known.isNotEmpty) return trackFacts(known.first['id'] as int);
    final m = readAudioMeta(path);
    return AudioFacts(
      path: path,
      format: m.format ?? p.extension(path).replaceFirst('.', '').toUpperCase(),
      codec: m.codec,
      lossless: m.lossless,
      bitrateKbps: m.bitrateKbps,
      sampleRate: m.sampleRate,
      bitDepth: m.bitDepth,
      channels: m.channels,
      durationMs: m.durationMs,
      sizeBytes: File(path).lengthSync(),
    );
  }

  /// Other library tracks with the same artist and title (letters and digits
  /// only, accents and case ignored), best first: lossless, then higher
  /// bitrate. Different versions (a remix, an edit) share the title only when
  /// their tags say so, so the length difference is shown too.
  List<OwnedAlternative> owned(int id) {
    final me = trackFacts(id);
    final all = libraryMatchTracks(cat);
    final self = all.where((x) => x.id == id).firstOrNull;
    if (self == null) return const [];
    final a = matchKey(self.artist), t = matchKey(self.title);
    if (t.isEmpty) return const [];
    final out = <OwnedAlternative>[];
    for (final x in all) {
      if (x.id == id || matchKey(x.title) != t) continue;
      if (a.isNotEmpty &&
          matchKey(x.artist) != a &&
          compareArtists(self.artist, x.artist) == ArtistOverlap.none) {
        continue;
      }
      final f = trackFacts(x.id);
      if (!File(f.path).existsSync()) continue;
      final reasons = <String>[
        if (f.lossless == true) 'lossless',
        if (f.lossless != true &&
            f.bitrateKbps != null &&
            (me.bitrateKbps ?? 0) < f.bitrateKbps!)
          '${f.bitrateKbps} kbps',
      ];
      final diff = me.durationMs == null || f.durationMs == null
          ? null
          : (f.durationMs! - me.durationMs!) / 1000;
      out.add(OwnedAlternative(f, reasons, diff));
    }
    int score(OwnedAlternative o) =>
        (o.facts.lossless == true ? 100000 : 0) + (o.facts.bitrateKbps ?? 0);
    out.sort((x, y) => score(y).compareTo(score(x)));
    return out;
  }

  /// The gain (dB) to play [b] at so it sounds as loud as [a], when both have
  /// been analysed; louder files otherwise sound "better" in a comparison.
  static double? matchGainDb(AudioFacts a, AudioFacts b) {
    if (a.lufs == null || b.lufs == null) return null;
    return (a.lufs! - b.lufs!).clamp(-24.0, 24.0);
  }
}
