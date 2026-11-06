import 'package:flutter/material.dart';

import '../core/rule_fields.g.dart';
import 'theme.dart';

typedef Node = Map<String, Object?>;

class RuleOp {
  const RuleOp(this.id, this.label, this.arity);
  final String id, label;
  final int arity;
}

/// Operators per field kind (1.x `src/lib/rules.ts`).
const ruleOps = <String, List<RuleOp>>{
  'text': [
    RuleOp('contains', 'contains', 1),
    RuleOp('equals', 'is', 1),
    RuleOp('not_contains', 'does not contain', 1),
    RuleOp('not_equals', 'is not', 1),
    RuleOp('starts_with', 'starts with', 1),
    RuleOp('is_empty', 'is unknown', 0),
    RuleOp('is_not_empty', 'is known', 0),
  ],
  'number': [
    RuleOp('between', 'between', 2),
    RuleOp('eq', '=', 1),
    RuleOp('gte', '≥', 1),
    RuleOp('lte', '≤', 1),
    RuleOp('gt', '>', 1),
    RuleOp('lt', '<', 1),
    RuleOp('neq', '≠', 1),
    RuleOp('is_empty', 'is unknown', 0),
    RuleOp('is_not_empty', 'is known', 0),
  ],
  'enum': [
    RuleOp('equals', 'is', 1),
    RuleOp('not_equals', 'is not', 1),
    RuleOp('is_empty', 'is unknown', 0),
    RuleOp('is_not_empty', 'is known', 0),
  ],
  'tag': [
    RuleOp('has', 'has tag', 1),
    RuleOp('not_has', 'does not have tag', 1),
    RuleOp('is_empty', 'has no tags', 0),
  ],
  'bool': [RuleOp('is_true', 'yes', 0), RuleOp('is_false', 'no', 0)],
};

String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

final enumValues = <String, List<(String, String)>>{
  'quality': [
    ('lossless', 'Lossless'),
    ('lossy', 'Lossy'),
    ('low_bitrate', 'Low bitrate'),
    ('unknown', 'Unknown'),
  ],
  'status': [
    ('ok', 'OK'),
    ('error', 'Unreadable'),
    ('unsupported', 'Unsupported'),
    ('offline', 'Offline'),
    ('missing', 'Missing'),
  ],
  'clean_explicit': [('clean', 'Clean'), ('explicit', 'Explicit')],
  'color': [for (final c in crateColors.keys) (c, _cap(c))],
  'extension': [
    for (final e in [
      'mp3',
      'flac',
      'wav',
      'aiff',
      'aif',
      'm4a',
      'ogg',
      'opus',
      'wma',
    ])
      (e, e.toUpperCase()),
  ],
  'media': [('audio', 'Audio'), ('video', 'Video')],
};

RuleField? fieldOf(String id) =>
    ruleFields.where((f) => f.id == id).firstOrNull;

Node cond(String field, String op, [Object? value]) => {
  'kind': 'condition',
  'field': field,
  'op': op,
  'value': value,
};

RuleOp? opOf(Node n) {
  final f = fieldOf('${n['field']}');
  return f == null
      ? null
      : ruleOps[f.kind]?.where((o) => o.id == n['op']).firstOrNull;
}

String _num(Object? v) =>
    v is num && v == v.roundToDouble() ? '${v.round()}' : '$v';

String describeRule(Node node) {
  if (node['kind'] == 'group') {
    final rules = (node['rules'] as List?)?.cast<Node>() ?? const [];
    return '(${rules.map(describeRule).join(node['match'] == 'all' ? ' and ' : ' or ')})';
  }
  final f = fieldOf('${node['field']}');
  final label = f?.label ?? '${node['field']}';
  final op = opOf(node);
  if (op == null || op.arity == 0) return '$label ${op?.label ?? node['op']}';
  final v = node['value'];
  if (op.arity == 2 && v is List && v.length == 2) {
    return '$label ${_num(v[0])}–${_num(v[1])}';
  }
  final e = enumValues['${node['field']}']?.where((x) => x.$1 == v).firstOrNull;
  return '$label ${op.label} ${e?.$2 ?? _num(v)}';
}

int countRules(Node? rs) => rs == null
    ? 0
    : ((rs['rules'] as List?)?.length ?? 0) +
          ((rs['exclude'] as List?)?.length ?? 0);

num? _toNum(Object? v) => v is num ? v : num.tryParse('${v ?? ''}'.trim());

bool _complete(Node c) {
  final f = fieldOf('${c['field']}');
  final op = opOf(c);
  if (f == null || op == null) return false;
  if (op.arity == 0) return true;
  final v = c['value'];
  if (op.arity == 2) {
    return v is List && v.length == 2 && v.every((x) => _toNum(x) != null);
  }
  if (f.kind == 'number') return _toNum(v) != null;
  return v is String && v.trim().isNotEmpty;
}

Node _normalise(Node c) {
  final f = fieldOf('${c['field']}');
  var v = c['value'];
  if (f?.kind == 'number') {
    v = v is List ? [for (final x in v) _toNum(x)] : _toNum(v);
  }
  return cond('${c['field']}', '${c['op']}', v);
}

/// Drops incomplete conditions; null when nothing is left.
Node? cleanRuleSet(Node? rs) {
  if (rs == null) return null;
  List<Node> clean(Object? nodes) => [
    for (final n in (nodes as List?)?.cast<Node>() ?? const <Node>[])
      if (n['kind'] == 'group')
        if (clean(n['rules']) case final inner when inner.isNotEmpty)
          {...n, 'rules': inner}
        else
          ...[]
      else if (_complete(n))
        _normalise(n),
  ];
  final out = {
    'match': rs['match'] ?? 'all',
    'rules': clean(rs['rules']),
    'exclude': clean(rs['exclude']),
  };
  return ((out['rules']! as List).isEmpty && (out['exclude']! as List).isEmpty)
      ? null
      : out;
}

Node emptyRuleSet() => {'match': 'all', 'rules': <Node>[], 'exclude': <Node>[]};

/// A quick filter option ("Genre ▾ House").
class QuickOption {
  const QuickOption(this.label, this.node, [this.count]);
  final String label;
  final Node node;
  final int? count;
}

final formatOptions = <QuickOption>[
  for (final f in [
    'MP3',
    'FLAC',
    'WAV',
    'AIFF',
    'M4A (AAC)',
    'M4A (ALAC)',
    'Ogg Vorbis',
    'Opus',
  ])
    QuickOption(f, cond('format', 'equals', f)),
  QuickOption('All video', cond('media', 'equals', 'video')),
  QuickOption('Audio only', cond('media', 'equals', 'audio')),
  for (final f in ['MP4', 'MOV', 'MKV', 'WebM', 'AVI'])
    QuickOption('$f video', cond('format', 'equals', f)),
];

final qualityOptions = <QuickOption>[
  QuickOption('Low bitrate', cond('quality', 'equals', 'low_bitrate')),
  QuickOption('Lossy', cond('quality', 'equals', 'lossy')),
  QuickOption('Lossless', cond('quality', 'equals', 'lossless')),
  QuickOption('Unknown', cond('quality', 'equals', 'unknown')),
  QuickOption('Video (HD 720p+)', {
    'kind': 'group',
    'match': 'all',
    'rules': [
      cond('media', 'equals', 'video'),
      cond('video_height', 'gte', 720),
    ],
  }),
  QuickOption('Video (below 720p)', {
    'kind': 'group',
    'match': 'all',
    'rules': [
      cond('media', 'equals', 'video'),
      cond('video_height', 'lt', 720),
    ],
  }),
];

/// Edits a rule set: match all/any, conditions and exclusions.
class RuleBuilder extends StatefulWidget {
  const RuleBuilder({
    super.key,
    required this.initial,
    required this.onChanged,
  });
  final Node initial;
  final ValueChanged<Node> onChanged;
  @override
  State<RuleBuilder> createState() => _RuleBuilderState();
}

class _RuleBuilderState extends State<RuleBuilder> {
  late String match = '${widget.initial['match'] ?? 'all'}';
  late final rules = [
    for (final n
        in (widget.initial['rules'] as List?)?.cast<Node>() ?? const <Node>[])
      Map<String, Object?>.of(n),
  ];
  late final exclude = [
    for (final n
        in (widget.initial['exclude'] as List?)?.cast<Node>() ?? const <Node>[])
      Map<String, Object?>.of(n),
  ];

  void _emit() =>
      widget.onChanged({'match': match, 'rules': rules, 'exclude': exclude});

  Widget _row(List<Node> list, int i) {
    final n = list[i];
    if (n['kind'] == 'group') {
      return ListTile(
        dense: true,
        title: Text(describeRule(n)),
        trailing: IconButton(
          tooltip: 'Remove',
          icon: const Icon(Icons.close, size: 18),
          onPressed: () => setState(() {
            list.removeAt(i);
            _emit();
          }),
        ),
      );
    }
    final f = fieldOf('${n['field']}') ?? ruleFields.first;
    final ops = ruleOps[f.kind]!;
    final op = ops.where((o) => o.id == n['op']).firstOrNull ?? ops.first;
    Widget valueBox(int idx) {
      final cur = op.arity == 2
          ? ((n['value'] is List && (n['value']! as List).length == 2)
                ? (n['value']! as List)[idx]
                : null)
          : n['value'];
      final ev = enumValues[f.id];
      if (ev != null && op.arity == 1) {
        return DropdownButton<String>(
          isExpanded: true,
          style: Theme.of(context).textTheme.bodyMedium,
          value: ev.any((e) => e.$1 == cur) ? '$cur' : null,
          hint: const Text('choose'),
          items: [
            for (final e in ev)
              DropdownMenuItem(value: e.$1, child: Text(e.$2)),
          ],
          onChanged: (v) => setState(() {
            n['value'] = v;
            _emit();
          }),
        );
      }
      return SizedBox(
        width: op.arity == 2 ? 80 : 180,
        child: TextFormField(
          key: ValueKey('${n.hashCode}-$idx-${op.id}'),
          initialValue: cur == null ? '' : '$cur',
          keyboardType: f.kind == 'number'
              ? TextInputType.number
              : TextInputType.text,
          onChanged: (v) {
            if (op.arity == 2) {
              final pair =
                  n['value'] is List && (n['value']! as List).length == 2
                  ? List<Object?>.of(n['value']! as List)
                  : <Object?>['', ''];
              pair[idx] = v;
              n['value'] = pair;
            } else {
              n['value'] = v;
            }
            _emit();
          },
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        children: [
          DropdownButton<String>(
            isExpanded: true,
            style: Theme.of(context).textTheme.bodyMedium,
            value: f.id,
            items: [
              for (final x in ruleFields)
                DropdownMenuItem(value: x.id, child: Text(x.label)),
            ],
            onChanged: (v) => setState(() {
              final nf = fieldOf(v!)!;
              n
                ..['field'] = v
                ..['op'] = ruleOps[nf.kind]!.first.id
                ..['value'] = null;
              _emit();
            }),
          ),
          DropdownButton<String>(
            isExpanded: true,
            style: Theme.of(context).textTheme.bodyMedium,
            value: op.id,
            items: [
              for (final o in ops)
                DropdownMenuItem(value: o.id, child: Text(o.label)),
            ],
            onChanged: (v) => setState(() {
              n
                ..['op'] = v
                ..['value'] = null;
              _emit();
            }),
          ),
          if (op.arity >= 1) valueBox(0),
          if (op.arity == 2) ...[const Text('and'), valueBox(1)],
          IconButton(
            tooltip: 'Remove',
            icon: const Icon(Icons.close, size: 18),
            onPressed: () => setState(() {
              list.removeAt(i);
              _emit();
            }),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = DjTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            const Text('Match'),
            const SizedBox(width: 8),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'all', label: Text('all')),
                ButtonSegment(value: 'any', label: Text('any')),
              ],
              selected: {match},
              onSelectionChanged: (s) => setState(() {
                match = s.first;
                _emit();
              }),
            ),
            const SizedBox(width: 8),
            const Text('of these'),
          ],
        ),
        const SizedBox(height: 8),
        for (var i = 0; i < rules.length; i++) _row(rules, i),
        TextButton.icon(
          onPressed: () => setState(() {
            rules.add(cond('genre', 'contains', ''));
            _emit();
          }),
          icon: const Icon(Icons.add, size: 18),
          label: const Text('Add condition'),
        ),
        const SizedBox(height: 8),
        Text('Leave out tracks where…', style: TextStyle(color: t.faint)),
        for (var i = 0; i < exclude.length; i++) _row(exclude, i),
        TextButton.icon(
          onPressed: () => setState(() {
            exclude.add(cond('version', 'contains', ''));
            _emit();
          }),
          icon: const Icon(Icons.remove_circle_outline, size: 18),
          label: const Text('Add exclusion'),
        ),
      ],
    );
  }
}

/// Opens the rule builder in a dialog; returns the cleaned rule set (or null).
Future<Node?> editRules(
  BuildContext context,
  Node? initial, {
  String title = 'More filters',
}) async {
  var draft = initial ?? emptyRuleSet();
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 680,
        child: SingleChildScrollView(
          child: RuleBuilder(initial: draft, onChanged: (v) => draft = v),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(c, true),
          child: const Text('Apply'),
        ),
      ],
    ),
  );
  return ok == true ? (cleanRuleSet(draft) ?? emptyRuleSet()) : null;
}
