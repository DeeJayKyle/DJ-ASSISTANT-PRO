/// JSON views of the core models, with 1.x's keys (the assistant's tools, the
/// UI and exports read them).
library;

import 'crates.dart';
import 'duplicates.dart';
import 'health.dart';
import 'library.dart';
import 'sets.dart';
import 'suggestions.dart';
import 'templates.dart';

extension TrackRowJson on TrackRow {
  Map<String, Object?> toJson() => {
    'id': id,
    'uid': uid,
    'title': title,
    'artist': artist,
    'album': album,
    'genre': genre,
    'year': year,
    'original_year': originalYear,
    'bpm': bpm,
    'key': key,
    'energy': energy,
    'rating': rating,
    'mood': mood,
    'color': color,
    'version': version,
    'clean_explicit': cleanExplicit,
    'duration_ms': durationMs,
    'bitrate_kbps': bitrateKbps,
    'format': format,
    'lossless': lossless,
    'quality': quality,
    'status': status,
    'file_name': fileName,
    'path': path,
    'file_size': fileSize,
    'tags': tags,
    'bpm_source': bpmSource,
    'key_source': keySource,
    'energy_source': energySource,
    'analysis': analysis,
    'media_kind': mediaKind,
  };
}

extension CrateJson on Crate {
  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'kind': kind,
    'color': color,
    'category': category,
    'parent_id': parentId,
    'sort_order': sortOrder,
    'rules': rules,
    'track_count': trackCount,
    'created_at': createdAt,
    'updated_at': updatedAt,
  };
}

extension HealthItemJson on HealthItem {
  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'explanation': explanation,
    'count': count,
    'filters': filters,
    'include_missing': includeMissing,
    'fix_fields': fixFields,
  };
}

extension DupGroupJson on DupGroup {
  Map<String, Object?> toJson() => {
    'kind': kind,
    'key': key,
    'reason': reason,
    'decision': decision,
    'tracks': [for (final t in tracks) t.toJson()],
  };
}

extension SuggestionJson on Suggestion {
  Map<String, Object?> toJson() => {
    'id': id,
    'track_id': trackId,
    'track': track,
    'field': field,
    'current_value': currentValue,
    'suggested_value': suggestedValue,
    'source': source,
    'evidence': evidence,
    'confidence': confidence,
    'status': status,
    'created_at': createdAt,
  };
}

extension TemplateJson on CrateTemplate {
  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'description': description,
    'crates': crates,
    'needs_genre': needsGenre,
  };
}

List<int> _ints(Object? v) => [
  for (final x in v is List ? v : const []) ?(x is num ? x.toInt() : null),
];
List<String> _strs(Object? v) => [
  for (final x in v is List ? v : const []) ?(x is String ? x : null),
];
double? _num(Object? v) => v is num ? v.toDouble() : null;

/// Set parameters from a JSON object (the set planner screen, the assistant).
SetParams setParamsFromJson(Map<String, Object?> j) => SetParams(
  durationMin: (j['duration_min'] as num?)?.toInt() ?? 60,
  name: j['name'] as String?,
  eventType: j['event_type'] as String?,
  audience: j['audience'] as String?,
  genres: _strs(j['genres']),
  mustPlay: _ints(j['must_play']),
  exclude: _ints(j['exclude']),
  excludeTags: _strs(j['exclude_tags']),
  cleanOnly: j['clean_only'] == true,
  curve: j['curve'] as String?,
  customCurve: [
    for (final x
        in j['custom_curve'] is List ? j['custom_curve']! as List : const [])
      ?_num(x),
  ],
  bpmMin: _num(j['bpm_min']),
  bpmMax: _num(j['bpm_max']),
  crateId: (j['crate_id'] as num?)?.toInt(),
  harmonic: j['harmonic'] as bool?,
  minTrackSeconds: (j['min_track_seconds'] as num?)?.toInt(),
);
