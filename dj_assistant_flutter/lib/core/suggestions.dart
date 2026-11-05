import 'catalogue.dart';
import 'text.dart';

/// Fields a suggestion may target (1.x `suggest::FIELDS`).
const suggestionFields = [
  'title',
  'artist',
  'album',
  'genre',
  'year',
  'original_year',
  'bpm',
  'key',
  'version_label',
  'record_label',
];

/// Records (or refreshes) a pending suggestion. Nothing is written to files; the
/// DJ accepts suggestions into the catalogue. Ignored when the value is empty or
/// already the current one.
void insertSuggestion(
  Catalogue cat,
  int trackId,
  String field,
  String? current,
  String value,
  String source,
  String evidence,
  double confidence,
) {
  if (!suggestionFields.contains(field) || value.trim().isEmpty) return;
  if (current != null && fold(current.trim()) == fold(value.trim())) return;
  cat.db.execute(
    'INSERT INTO suggestions (track_id, field, current_value, suggested_value, source, evidence, confidence, status, created_at) '
    "VALUES (?,?,?,?,?,?,?,'pending',?) "
    'ON CONFLICT(track_id, field, suggested_value, source) DO UPDATE SET current_value=excluded.current_value, '
    'evidence=excluded.evidence, confidence=excluded.confidence',
    [
      trackId,
      field,
      current,
      value.trim(),
      source,
      evidence,
      confidence.clamp(0.0, 1.0),
      nowMs(),
    ],
  );
}

/// A number as Rust's `{}` prints it ("140", "180.5"), so stored text matches 1.x.
String rustNumber(double v) => (v == v.truncateToDouble() && v.abs() < 1e15)
    ? v.toInt().toString()
    : v.toString();
