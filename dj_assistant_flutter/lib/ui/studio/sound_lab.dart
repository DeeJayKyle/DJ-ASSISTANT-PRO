import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_soloud/flutter_soloud.dart';

import '../../core/diag_log.dart';
import '../../assistant/quick_ai.dart' show extractJson;
import '../../studio/drums.dart';
import '../../studio/dsp.dart' show encodeWav;
import '../../studio/midi_in.dart';
import '../../studio/synth.dart';
import '../player.dart' show AudioEngine;
import '../state.dart';
import '../theme.dart';
import 'common.dart';

const _sr = 44100;
const _noteNames = [
  'C',
  'C#',
  'D',
  'D#',
  'E',
  'F',
  'F#',
  'G',
  'G#',
  'A',
  'A#',
  'B',
];
const _keys = 'awsedftgyhujkolp;';

List<T> _shuffle<T>(List<T> a, int n) => ([...a]..shuffle()).take(n).toList();

/// Plays rendered sounds; a voice can be released with a fade.
class _Voices {
  final _cache = <String, AudioSource>{};
  final _live = <String, SoundHandle>{};
  SoLoud get _sl => SoLoud.instance;

  Future<void> start(
    String id,
    String key,
    List<Float32List> Function() render,
  ) async {
    if (!await AudioEngine.instance.ready()) return;
    var src = _cache[key];
    if (src == null) {
      src = await _sl.loadMem('lab-$key.wav', encodeWav(render(), _sr));
      _cache[key] = src;
    }
    final old = _live[id];
    if (old != null && _sl.getIsValidVoiceHandle(old)) unawaited(_sl.stop(old));
    _live[id] = _sl.play(src);
  }

  void release(String id, double seconds) {
    final h = _live.remove(id);
    if (h == null || !_sl.getIsValidVoiceHandle(h)) return;
    final d = Duration(milliseconds: (math.max(0.02, seconds) * 1000).round());
    _sl
      ..fadeVolume(h, 0, d)
      ..scheduleStop(h, d + const Duration(milliseconds: 20));
  }

  Future<void> clear() async {
    for (final h in _live.values) {
      if (_sl.getIsValidVoiceHandle(h)) await _sl.stop(h);
    }
    _live.clear();
    for (final s in _cache.values) {
      await _sl.disposeSource(s);
    }
    _cache.clear();
  }
}

bool _typing() {
  final f = FocusManager.instance.primaryFocus?.context?.widget;
  return f is EditableText;
}

/// Synth Lab: describe a sound, get a playable instrument; fine-tune; download
/// WAV samples + SFZ.
class SynthLab extends ConsumerStatefulWidget {
  const SynthLab({super.key, this.active = true});
  final bool active;
  @override
  ConsumerState<SynthLab> createState() => _SynthLabState();
}

class _SynthLabState extends ConsumerState<SynthLab> {
  final prompt = TextEditingController(
    text: 'warm analog pad with slow attack',
  );
  int seed = 1;
  Patch patch = patchFromPrompt('warm analog pad with slow attack', 1);
  List<String> ideas = _shuffle(synthIdeas, 5);
  int octave = 4;
  final down = <int>{};
  bool busy = false;
  String? midiName;
  final voices = _Voices();
  final _held = <String>{};

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_key);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_key);
    unawaited(voices.clear());
    prompt.dispose();
    super.dispose();
  }

  void _changed(VoidCallback f) {
    setState(f);
    unawaited(voices.clear());
  }

  Future<void> make(String text, [int s = 1]) async {
    prompt.text = text;
    var p = patchFromPrompt(text, s);
    final ai = studioAi(ref);
    if (ai != null && s == 1) {
      setState(() => busy = true);
      try {
        p = patchFromAi(
          extractJson(await ai(aiSynthSystem, 'Design a patch for: $text')),
          p,
        );
      } on Object {
        // the rules are enough
      }
      if (mounted) setState(() => busy = false);
    }
    _changed(() {
      seed = s;
      patch = p;
    });
  }

  void noteOn(int midi, [double vel = 0.9]) {
    final key =
        '${jsonEncode(patch.toJson()).hashCode}:$midi:${vel.toStringAsFixed(1)}';
    final pt = patch;
    unawaited(
      voices.start(
        '$midi',
        key,
        () => renderNote(pt, midi, 6, sampleRate: _sr, velocity: vel),
      ),
    );
    setState(() => down.add(midi));
  }

  void noteOff(int midi) {
    voices.release('$midi', patch.amp.r);
    setState(() => down.remove(midi));
  }

  bool _key(KeyEvent e) {
    if (!widget.active || !mounted || _typing()) return false;
    final ch =
        e.character?.toLowerCase() ?? e.logicalKey.keyLabel.toLowerCase();
    if (HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed) {
      return false;
    }
    if (e is KeyDownEvent) {
      if (ch == 'z') {
        setState(() => octave = math.max(1, octave - 1));
        return true;
      }
      if (ch == 'x') {
        setState(() => octave = math.min(7, octave + 1));
        return true;
      }
      final i = _keys.indexOf(ch);
      if (ch.isEmpty || i < 0 || _held.contains(ch)) return false;
      _held.add(ch);
      noteOn(12 * (octave + 1) + i);
      return true;
    }
    if (e is KeyUpEvent) {
      final k = e.logicalKey.keyLabel.toLowerCase();
      final i = _keys.indexOf(k);
      if (k.isEmpty || i < 0 || !_held.remove(k)) return false;
      noteOff(12 * (octave + 1) + i);
      return true;
    }
    return false;
  }

  void connectMidi() {
    try {
      final m = MidiInput.instance;
      m.onNote = (n, on, v) => on ? noteOn(n, v) : noteOff(n);
      setState(() => midiName = m.connect().join(', '));
    } on Object catch (e, st) {
      DiagLog.error('sound-lab', e, st);
      toast(errText(e), error: true);
    }
  }

  Future<void> download() async {
    await guard(() async {
      final files = instrumentFiles(patch, sampleRate: _sr);
      final where = await saveStudioFiles(patch.name, files);
      if (where != null) {
        toast('Saved ${files.length - 2} samples and an SFZ instrument.');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = DjTokens.of(context);
    final first = 12 * (octave + 1);
    Knob k(
      String label,
      double v,
      double min,
      double max,
      void Function(double) set, [
      String Function(double)? f,
    ]) => Knob(
      label: label,
      value: v,
      min: min,
      max: max,
      format: f,
      onChanged: (x) => _changed(() => set(x)),
    );
    String secs(double v) => '${v.toStringAsFixed(2)} s';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        StudioPanel(
          title: 'Describe an instrument',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: prompt,
                      decoration: const InputDecoration(
                        hintText: 'e.g. dark thick sub bass',
                        labelText: 'Describe the sound',
                      ),
                      onSubmitted: (v) => v.trim().isEmpty ? null : make(v),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: busy ? null : () => make(prompt.text),
                    child: Text(busy ? 'Designing…' : 'Make it'),
                  ),
                  IconButton(
                    tooltip: 'Previous variation',
                    onPressed: () => make(prompt.text, math.max(1, seed - 1)),
                    icon: const Icon(Icons.chevron_left),
                  ),
                  IconButton(
                    tooltip: 'Next variation',
                    onPressed: () => make(prompt.text, seed + 1),
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final i in ideas)
                    ActionChip(label: Text(i), onPressed: () => make(i)),
                  TextButton(
                    onPressed: () =>
                        setState(() => ideas = _shuffle(synthIdeas, 5)),
                    child: const Text('New ideas'),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        StudioPanel(
          title: '${patch.name}  ·  variation $seed',
          trailing: [
            Text('Octave $octave (Z / X)', style: TextStyle(color: t.muted)),
            OutlinedButton(
              onPressed: connectMidi,
              child: Text(
                midiName == null
                    ? 'Connect MIDI controller'
                    : 'MIDI: $midiName',
              ),
            ),
            FilledButton(
              onPressed: download,
              child: const Text('Download instrument'),
            ),
          ],
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: 120,
                child: Row(
                  children: [
                    for (var m = first; m <= first + 16; m++)
                      Expanded(child: _key2(m, m - first, t)),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                children: [
                  k(
                    'Cutoff',
                    patch.filter.cutoff,
                    60,
                    16000,
                    (v) => patch.filter.cutoff = v,
                    (v) => '${v.round()} Hz',
                  ),
                  k(
                    'Resonance',
                    patch.filter.resonance,
                    0,
                    0.9,
                    (v) => patch.filter.resonance = v,
                  ),
                  k(
                    'Attack',
                    patch.amp.a,
                    0.001,
                    2,
                    (v) => patch.amp.a = v,
                    secs,
                  ),
                  k(
                    'Decay',
                    patch.amp.d,
                    0.01,
                    3,
                    (v) => patch.amp.d = v,
                    secs,
                  ),
                  k('Sustain', patch.amp.s, 0, 1, (v) => patch.amp.s = v),
                  k(
                    'Release',
                    patch.amp.r,
                    0.01,
                    4,
                    (v) => patch.amp.r = v,
                    secs,
                  ),
                  k('Drive', patch.drive, 0, 1, (v) => patch.drive = v),
                  k('Width', patch.spread, 0, 60, (v) {
                    patch.spread = v;
                    patch.unison = math.max(patch.unison, v > 0 ? 3 : 1);
                  }, (v) => '${v.round()} ct'),
                  k(
                    'Reverb',
                    patch.reverbMix,
                    0,
                    1,
                    (v) => patch.reverbMix = v,
                  ),
                ],
              ),
              Text(
                'Play with your computer keys (A W S E D…), the on-screen keys or a MIDI controller. The download has samples every four semitones plus an .sfz file most samplers can open.',
                style: TextStyle(color: t.faint, fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _key2(int m, int idx, DjTokens t) {
    final black = const [1, 3, 6, 8, 10].contains(m % 12);
    final on = down.contains(m);
    return Semantics(
      button: true,
      label: '${_noteNames[m % 12]}${m ~/ 12 - 1}',
      child: Listener(
        onPointerDown: (_) => noteOn(m),
        onPointerUp: (_) => noteOff(m),
        onPointerCancel: (_) => noteOff(m),
        child: Container(
          margin: EdgeInsets.only(right: 2, bottom: black ? 40 : 0),
          decoration: BoxDecoration(
            color: on
                ? t.accent
                : black
                ? const Color(0xFF1B2028)
                : const Color(0xFFE8ECF1),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: t.line),
          ),
          alignment: Alignment.bottomCenter,
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(
            idx < _keys.length ? _keys[idx].toUpperCase() : '',
            style: TextStyle(
              fontSize: 10,
              color: black ? Colors.white70 : Colors.black54,
            ),
          ),
        ),
      ),
    );
  }
}

/// Drum Lab: describe a kit, get 16 playable pads; tweak each pad; a 16-step
/// pattern; download WAV + SFZ.
class DrumLab extends ConsumerStatefulWidget {
  const DrumLab({super.key, this.active = true});
  final bool active;
  @override
  ConsumerState<DrumLab> createState() => _DrumLabState();
}

class _DrumLabState extends ConsumerState<DrumLab> {
  final prompt = TextEditingController(
    text: 'deep punchy techno kick-driven groove',
  );
  Kit kit = kitFromPrompt('deep punchy techno kick-driven groove', 1);
  List<String> ideas = _shuffle(drumIdeas, 5);
  int sel = 0;
  int? hit;
  bool midiOn = false;
  final voices = _Voices();
  late Pattern pat = defaultPattern(kit);
  // sequencer
  AudioSource? _loop;
  SoundHandle? _loopH;
  double _loopLen = 1;
  int step = -1;
  Timer? _tick;
  bool playing = false;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_key);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_key);
    _tick?.cancel();
    unawaited(_stopLoop());
    unawaited(voices.clear());
    prompt.dispose();
    super.dispose();
  }

  SoLoud get _sl => SoLoud.instance;

  void make(String text, [int seed = 1]) {
    prompt.text = text;
    setState(() {
      kit = kitFromPrompt(text, seed);
      if (pat.grid.length != kit.pads.length) {
        pat = defaultPattern(kit, pat.bpm);
      }
      sel = sel.clamp(0, kit.pads.length - 1);
    });
    unawaited(voices.clear());
    _replay();
  }

  void play(int i, [double vel = 1]) {
    final p = kit.pads[i];
    final key = '${jsonEncode(p.toJson()).hashCode}:${vel.toStringAsFixed(1)}';
    unawaited(
      voices.start(
        'pad$i${p.type.contains('Hat') ? 'hat' : ''}',
        key,
        () => renderPad(p, sampleRate: _sr, velocity: vel),
      ),
    );
    setState(() => hit = i);
    Timer(const Duration(milliseconds: 120), () {
      if (mounted && hit == i) setState(() => hit = null);
    });
  }

  bool _key(KeyEvent e) {
    if (!widget.active || !mounted || _typing() || e is! KeyDownEvent) {
      return false;
    }
    if (HardwareKeyboard.instance.isControlPressed) return false;
    final ch = e.character?.toLowerCase() ?? '';
    final i = kit.pads.indexWhere((p) => p.key == ch);
    if (ch.isEmpty || i < 0) return false;
    play(i);
    setState(() => sel = i);
    return true;
  }

  void connectMidi() {
    try {
      final m = MidiInput.instance;
      m.onNote = (n, on, v) {
        final i = kit.pads.indexWhere((p) => p.note == n);
        if (on && i >= 0) play(i, v);
      };
      m.connect();
      setState(() => midiOn = true);
    } on Object catch (e, st) {
      DiagLog.error('sound-lab', e, st);
      toast(errText(e), error: true);
    }
  }

  void setPad(void Function(Pad) f) {
    setState(() => f(kit.pads[sel]));
    _replay();
  }

  Future<void> download() async {
    await guard(() async {
      final files = kitFiles(kit, sampleRate: _sr);
      final where = await saveStudioFiles(kit.name, files);
      if (where != null) {
        toast('Saved ${kit.pads.length} drum samples and an SFZ kit.');
      }
    });
  }

  // ---- sequencer

  Future<void> _stopLoop() async {
    final h = _loopH, s = _loop;
    _loopH = null;
    _loop = null;
    if (h != null && _sl.getIsValidVoiceHandle(h)) await _sl.stop(h);
    if (s != null) await _sl.disposeSource(s);
  }

  Future<void> _startLoop() async {
    if (!await AudioEngine.instance.ready()) return;
    final audio = renderPattern(kit, pat, bars: 1, sampleRate: _sr);
    final src = await _sl.loadMem(
      'pattern-${DateTime.now().microsecondsSinceEpoch}.wav',
      encodeWav(audio, _sr),
    );
    // keep the bar position when re-rendering mid-play, so edits don't jump
    final oldH = _loopH, oldS = _loop;
    var offset = 0.0;
    if (oldH != null && _sl.getIsValidVoiceHandle(oldH)) {
      offset = (_sl.getPosition(oldH).inMicroseconds / 1e6) % _loopLen;
    }
    final len = audio[0].length / _sr;
    final h = _sl.play(src, looping: true, paused: true);
    _sl
      ..seek(h, Duration(microseconds: (offset * len / _loopLen * 1e6).round()))
      ..setPause(h, false);
    _loop = src;
    _loopH = h;
    _loopLen = len;
    if (oldH != null && _sl.getIsValidVoiceHandle(oldH)) await _sl.stop(oldH);
    if (oldS != null) await _sl.disposeSource(oldS);
  }

  void _replay() {
    if (playing) unawaited(_startLoop());
  }

  Future<void> togglePlay() async {
    if (playing) {
      _tick?.cancel();
      await _stopLoop();
      setState(() {
        playing = false;
        step = -1;
      });
      return;
    }
    setState(() => playing = true);
    await _startLoop();
    _tick = Timer.periodic(const Duration(milliseconds: 30), (_) {
      final h = _loopH;
      if (!mounted || h == null || !_sl.getIsValidVoiceHandle(h)) return;
      final tm = (_sl.getPosition(h).inMicroseconds / 1e6) % _loopLen;
      final times = stepTimes(pat);
      var k = 0;
      while (k + 1 < steps && times[k + 1] <= tm) {
        k++;
      }
      if (k != step) setState(() => step = k);
    });
  }

  void editPat(void Function() f) {
    setState(f);
    _replay();
  }

  Future<void> savePattern(String kind) async {
    await guard(() async {
      final bytes = kind == 'wav'
          ? encodeWav(renderPattern(kit, pat, bars: 4, sampleRate: _sr), _sr)
          : patternMidi(kit, pat);
      final where = await saveStudioFile(
        '${safeName(kit.name)} ${pat.bpm.round()} bpm.$kind',
        bytes,
      );
      if (where != null) {
        toast(
          kind == 'wav' ? 'Saved a 4-bar loop.' : 'Saved the pattern as MIDI.',
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = DjTokens.of(context);
    final pad = kit.pads[sel];
    Widget k(
      String label,
      double v,
      double min,
      double max,
      void Function(Pad, double) set, [
      String Function(double)? f,
    ]) => Knob(
      label: label,
      value: v,
      min: min,
      max: max,
      format: f,
      onChanged: (x) => setState(() => set(pad, x)),
      onEnd: (_) {
        unawaited(voices.clear());
        _replay();
        play(sel);
      },
    );
    final rows = [
      for (var i = 0; i < kit.pads.length; i++)
        if (i < 8 || (i < pat.grid.length && pat.grid[i].any((x) => x))) i,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        StudioPanel(
          title: 'Describe a drum kit',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: prompt,
                      decoration: const InputDecoration(
                        hintText: 'e.g. crisp trap kit with booming 808',
                        labelText: 'Describe the kit',
                      ),
                      onSubmitted: (v) => v.trim().isEmpty ? null : make(v),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => make(prompt.text),
                    child: const Text('Make it'),
                  ),
                  IconButton(
                    tooltip: 'Previous variation',
                    onPressed: () =>
                        make(prompt.text, math.max(1, kit.seed - 1)),
                    icon: const Icon(Icons.chevron_left),
                  ),
                  IconButton(
                    tooltip: 'Next variation',
                    onPressed: () => make(prompt.text, kit.seed + 1),
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final i in ideas)
                    ActionChip(label: Text(i), onPressed: () => make(i)),
                  TextButton(
                    onPressed: () =>
                        setState(() => ideas = _shuffle(drumIdeas, 5)),
                    child: const Text('New ideas'),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            SizedBox(
              width: 520,
              child: StudioPanel(
                title: '${kit.name}  ·  variation ${kit.seed}',
                trailing: [
                  OutlinedButton(
                    onPressed: connectMidi,
                    child: Text(midiOn ? 'MIDI on' : 'MIDI controller'),
                  ),
                  FilledButton(
                    onPressed: download,
                    child: const Text('Download kit'),
                  ),
                ],
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    GridView.count(
                      crossAxisCount: 4,
                      shrinkWrap: true,
                      mainAxisSpacing: 6,
                      crossAxisSpacing: 6,
                      childAspectRatio: 1.6,
                      physics: const NeverScrollableScrollPhysics(),
                      children: [
                        for (var i = 0; i < kit.pads.length; i++)
                          Semantics(
                            button: true,
                            label:
                                '${kit.pads[i].name} (key ${kit.pads[i].key.toUpperCase()})',
                            child: Listener(
                              onPointerDown: (_) {
                                play(i);
                                setState(() => sel = i);
                              },
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 80),
                                decoration: BoxDecoration(
                                  color: hit == i
                                      ? t.accent
                                      : sel == i
                                      ? t.panel2
                                      : t.panel,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: sel == i ? t.accent : t.line,
                                  ),
                                ),
                                padding: const EdgeInsets.all(8),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      kit.pads[i].name,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    Text(
                                      kit.pads[i].key.toUpperCase(),
                                      style: TextStyle(
                                        color: t.faint,
                                        fontSize: 11,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Keys Z X C V / A S D F / Q W E R / 1 2 3 4, or MIDI notes 36–51.',
                      style: TextStyle(color: t.faint, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(
              width: 560,
              child: StudioPanel(
                title: pad.name,
                child: Wrap(
                  spacing: 10,
                  children: [
                    k(
                      'Pitch',
                      pad.pitch,
                      20,
                      2000,
                      (p, v) => p.pitch = v,
                      (v) => '${v.round()} Hz',
                    ),
                    k('Decay', pad.decay, 0.01, 2, (p, v) {
                      p.decay = v;
                      p.env.d = v;
                    }, (v) => '${v.toStringAsFixed(2)} s'),
                    k(
                      'Attack',
                      pad.env.a,
                      0.0005,
                      0.05,
                      (p, v) => p.env.a = v,
                      (v) => '${(v * 1000).toStringAsFixed(1)} ms',
                    ),
                    k('Tone', pad.tone, 0, 1, (p, v) => p.tone = v),
                    k('Noise', pad.noise, 0, 1, (p, v) => p.noise = v),
                    k('Drive', pad.drive, 0, 1, (p, v) => p.drive = v),
                    k('Room', pad.room, 0, 1, (p, v) => p.room = v),
                    k('Volume', pad.volume, 0, 1.5, (p, v) => p.volume = v),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        StudioPanel(
          title: 'Pattern',
          trailing: [
            Knob(
              label: 'Tempo',
              value: pat.bpm,
              min: 60,
              max: 180,
              format: (v) => '${v.round()} BPM',
              onChanged: (v) => setState(() => pat.bpm = v.roundToDouble()),
              onEnd: (_) => _replay(),
            ),
            Knob(
              label: 'Swing',
              value: pat.swing,
              min: 0,
              max: 0.6,
              format: (v) => '${(v * 100).round()}%',
              onChanged: (v) => setState(() => pat.swing = v),
              onEnd: (_) => _replay(),
            ),
            FilledButton(
              onPressed: togglePlay,
              child: Text(playing ? 'Stop pattern' : 'Play pattern'),
            ),
            OutlinedButton(
              onPressed: () => editPat(() {
                for (final r in pat.grid) {
                  r.fillRange(0, r.length, false);
                }
              }),
              child: const Text('Clear'),
            ),
            OutlinedButton(
              onPressed: () =>
                  editPat(() => pat = defaultPattern(kit, pat.bpm)),
              child: const Text('Reset groove'),
            ),
            OutlinedButton(
              onPressed: () => savePattern('wav'),
              child: const Text('Export loop (WAV)'),
            ),
            OutlinedButton(
              onPressed: () => savePattern('mid'),
              child: const Text('Export pattern (MIDI)'),
            ),
          ],
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final i in rows)
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 100,
                        child: Text(
                          kit.pads[i].name,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      for (var s = 0; s < steps; s++)
                        Expanded(child: _cell(i, s, t)),
                    ],
                  ),
                ),
              Text(
                'The first 8 pads are shown, plus any other pad with hits. Edits play straight away.',
                style: TextStyle(color: t.faint, fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _cell(int row, int s, DjTokens t) {
    final on = row < pat.grid.length && pat.grid[row][s];
    return Semantics(
      toggled: on,
      label: '${kit.pads[row].name} step ${s + 1}',
      child: GestureDetector(
        onTap: () => editPat(() => pat.grid[row][s] = !on),
        child: Container(
          height: 24,
          margin: const EdgeInsets.symmetric(horizontal: 1.5),
          decoration: BoxDecoration(
            color: on ? t.accent : (s % 4 == 0 ? t.panel2 : t.panel),
            borderRadius: BorderRadius.circular(3),
            border: Border.all(
              color: s == step
                  ? Theme.of(context).colorScheme.onSurface
                  : t.line,
            ),
          ),
        ),
      ),
    );
  }
}
