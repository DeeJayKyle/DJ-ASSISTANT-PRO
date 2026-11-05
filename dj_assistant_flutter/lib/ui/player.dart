import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_soloud/flutter_soloud.dart';

import 'format.dart';
import 'theme.dart';

/// Local file playback (1.x served `track://` to WebAudio; 2.0 plays files
/// straight from disk with SoLoud). Files are only read.
class AudioEngine {
  AudioEngine._();
  static final instance = AudioEngine._();
  Future<bool>? _ready;

  /// Starts the audio device once; false when there is no audio (tests, CI).
  Future<bool> ready() => _ready ??= () async {
    try {
      if (!SoLoud.instance.isInitialized) await SoLoud.instance.init();
      return true;
    } on Object {
      return false;
    }
  }();

  Future<AudioSource?> load(String path) async {
    if (!await ready()) return null;
    try {
      return await SoLoud.instance.loadFile(path, mode: LoadMode.disk);
    } on Object {
      return null;
    }
  }
}

/// Preview the 30 seconds around the cursor (track detail, suggestions…).
class PreviewPlayer extends StatefulWidget {
  const PreviewPlayer({super.key, required this.path, this.durationMs});
  final String path;
  final int? durationMs;
  @override
  State<PreviewPlayer> createState() => _PreviewPlayerState();
}

class _PreviewPlayerState extends State<PreviewPlayer> {
  AudioSource? src;
  SoundHandle? h;
  Timer? tick;
  double pos = 0;
  bool loading = false;
  String? err;

  SoLoud get sl => SoLoud.instance;

  Future<void> _toggle() async {
    if (h != null && sl.getIsValidVoiceHandle(h!)) {
      sl.setPause(h!, !sl.getPause(h!));
      setState(() {});
      return;
    }
    setState(() => loading = true);
    src ??= await AudioEngine.instance.load(widget.path);
    if (!mounted) return;
    if (src == null) {
      setState(() {
        loading = false;
        err = "Can't play this file here.";
      });
      return;
    }
    h = sl.play(src!);
    tick = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!mounted || h == null) return;
      if (!sl.getIsValidVoiceHandle(h!)) {
        setState(() => h = null);
        return;
      }
      final len = sl.getLength(src!).inMilliseconds;
      setState(
        () => pos = len == 0 ? 0 : sl.getPosition(h!).inMilliseconds / len,
      );
    });
    setState(() => loading = false);
  }

  @override
  void dispose() {
    tick?.cancel();
    if (h != null) unawaited(sl.stop(h!));
    if (src != null) unawaited(sl.disposeSource(src!));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = DjTokens.of(context);
    final playing =
        h != null &&
        sl.isInitialized &&
        sl.getIsValidVoiceHandle(h!) &&
        !sl.getPause(h!);
    final len = widget.durationMs ?? 0;
    return Row(
      children: [
        IconButton.filledTonal(
          tooltip: playing ? 'Pause' : 'Play preview',
          onPressed: loading ? null : _toggle,
          icon: Icon(playing ? Icons.pause : Icons.play_arrow),
        ),
        Expanded(
          child: Slider(
            value: pos.clamp(0, 1),
            onChanged: h == null || src == null
                ? null
                : (v) {
                    sl.seek(
                      h!,
                      Duration(
                        milliseconds: (v * sl.getLength(src!).inMilliseconds)
                            .round(),
                      ),
                    );
                    setState(() => pos = v);
                  },
          ),
        ),
        Text(
          err ?? '${fmtDuration((pos * len).round())} / ${fmtDuration(len)}',
          style: TextStyle(color: err != null ? t.warn : t.faint, fontSize: 12),
        ),
      ],
    );
  }
}
