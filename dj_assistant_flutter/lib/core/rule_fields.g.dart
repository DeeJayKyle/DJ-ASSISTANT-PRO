// Generated from 1.x crates/dj-core/src/rules.rs FIELD_LIST. Do not edit.

/// A field usable in filters and smart crates.
class RuleField {
  const RuleField(this.id, this.label, this.kind);
  final String id, label, kind;
  Map<String, String> toJson() => {'id': id, 'label': label, 'kind': kind};
}

const ruleFields = <RuleField>[
  RuleField('artist', 'Artist', 'text'),
  RuleField('title', 'Title', 'text'),
  RuleField('album', 'Album', 'text'),
  RuleField('album_artist', 'Album artist', 'text'),
  RuleField('genre', 'Genre', 'text'),
  RuleField('year', 'Year', 'number'),
  RuleField('original_year', 'Original year (tag)', 'number'),
  RuleField('decade', 'Decade', 'number'),
  RuleField('bpm', 'BPM', 'number'),
  RuleField('key', 'Key', 'text'),
  RuleField('energy', 'Energy (1–10)', 'number'),
  RuleField('rating', 'Rating (0–5)', 'number'),
  RuleField('mood', 'Mood', 'text'),
  RuleField('color', 'Colour', 'enum'),
  RuleField('tag', 'Tag', 'tag'),
  RuleField('version', 'Version label', 'text'),
  RuleField('clean_explicit', 'Clean / explicit', 'enum'),
  RuleField('label', 'Record label', 'text'),
  RuleField('composer', 'Composer', 'text'),
  RuleField('comment', 'Comment (file)', 'text'),
  RuleField('notes', 'My notes', 'text'),
  RuleField('format', 'Format', 'text'),
  RuleField('extension', 'File extension', 'enum'),
  RuleField('quality', 'Quality', 'enum'),
  RuleField('bitrate', 'Bitrate (kbps)', 'number'),
  RuleField('lossless', 'Lossless', 'bool'),
  RuleField('media', 'Media (audio / video)', 'enum'),
  RuleField('video_codec', 'Video codec', 'text'),
  RuleField('video_height', 'Video height (e.g. 1080)', 'number'),
  RuleField('frame_rate', 'Frame rate (fps)', 'number'),
  RuleField('duration', 'Duration (seconds)', 'number'),
  RuleField('sample_rate', 'Sample rate (Hz)', 'number'),
  RuleField('file_size_mb', 'File size (MB)', 'number'),
  RuleField('path', 'Location (path)', 'text'),
  RuleField('file_name', 'File name', 'text'),
  RuleField('status', 'Status', 'enum'),
];
