import 'package:intl/intl.dart';

import '../core/keys.dart';

/// Display helpers (1.x `src/lib/format.ts`).
const unknown = '—';

String fmtDuration(int? ms) {
  if (ms == null || ms <= 0) return unknown;
  final s = (ms / 1000).round();
  final h = s ~/ 3600, m = (s % 3600) ~/ 60;
  final sec = (s % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$sec' : '$m:$sec';
}

String fmtLongDuration(int ms) {
  final h = ms ~/ 3600000, m = ((ms % 3600000) / 60000).round();
  return h == 0 ? '$m min' : '$h h $m min';
}

String fmtBytes(int? n) {
  if (n == null) return unknown;
  const u = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = n.toDouble();
  var i = 0;
  while (v >= 1024 && i < u.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v >= 10 || i == 0 ? v.round() : v.toStringAsFixed(1)} ${u[i]}';
}

String fmtBpm(num? v) {
  if (v == null) return unknown;
  return v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(1);
}

String fmtText(Object? v) => (v == null || v == '') ? unknown : '$v';

String fmtDateTime(int? ms) {
  if (ms == null || ms == 0) return unknown;
  return DateFormat.yMMMd().add_jm().format(
    DateTime.fromMillisecondsSinceEpoch(ms),
  );
}

String fmtNumber(int n) => NumberFormat.decimalPattern().format(n);

String plural(int n, String word, [String? many]) =>
    '${fmtNumber(n)} ${n == 1 ? word : (many ?? '${word}s')}';

const qualityLabel = {
  'lossless': 'Lossless',
  'lossy': 'Lossy',
  'low_bitrate': 'Low bitrate',
  'unknown': 'Unknown',
  'video': 'Video',
};

const statusLabel = {
  'ok': 'OK',
  'error': 'Unreadable',
  'unsupported': 'Unsupported',
  'missing': 'Missing',
  'offline': 'Offline',
  'removed': 'Removed',
};

/// A key in the DJ's chosen notation; unrecognised text is shown as it is.
String fmtKey(String? k, String notation) {
  if (k == null || k.isEmpty) return unknown;
  final c = normalizeKey(k);
  if (c == null) return k;
  return notation == 'musical' ? (musicalName(c) ?? k) : c;
}

/// "8A = Am", for a hover hint.
String? keyHint(String? k) {
  if (k == null) return null;
  final c = normalizeKey(k);
  if (c == null) return null;
  return '$c = ${musicalName(c)}';
}

String resLabel(int? height) {
  if (height == null || height == 0) return unknown;
  if (height >= 2000) return '4K';
  if (height >= 1400) return '1440p';
  return '${height}p';
}

/// 83450 ms → "1:23.4".
String fmtCueTime(int ms) {
  final tenths = ms ~/ 100;
  final m = tenths ~/ 600, sec = (tenths % 600) / 10;
  return '$m:${sec.toStringAsFixed(1).padLeft(4, '0')}';
}
