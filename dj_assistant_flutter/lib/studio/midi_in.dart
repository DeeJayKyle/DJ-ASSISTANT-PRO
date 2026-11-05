import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// MIDI controllers on Windows (winmm), replacing 1.x's Web MIDI. Every input
/// device is opened; note-on/off messages arrive on the UI isolate.
class MidiInput {
  MidiInput._(this._lib);
  final DynamicLibrary _lib;
  final _handles = <int>[];
  NativeCallable<Void Function(IntPtr, Uint32, IntPtr, IntPtr, IntPtr)>? _cb;
  void Function(int note, bool on, double velocity)? onNote;

  static const _mimData = 0x3C3, _callbackFunction = 0x30000;

  static MidiInput? _instance;
  static MidiInput get instance => _instance ??= MidiInput._(
    Platform.isWindows
        ? DynamicLibrary.open('winmm.dll')
        : DynamicLibrary.process(),
  );

  late final _numDevs = _lib.lookupFunction<Uint32 Function(), int Function()>(
    'midiInGetNumDevs',
  );
  late final _caps = _lib
      .lookupFunction<
        Uint32 Function(IntPtr, Pointer<Uint8>, Uint32),
        int Function(int, Pointer<Uint8>, int)
      >('midiInGetDevCapsW');
  late final _open = _lib
      .lookupFunction<
        Uint32 Function(Pointer<IntPtr>, Uint32, IntPtr, IntPtr, Uint32),
        int Function(Pointer<IntPtr>, int, int, int, int)
      >('midiInOpen');
  late final _start = _lib
      .lookupFunction<Uint32 Function(IntPtr), int Function(int)>(
        'midiInStart',
      );
  late final _stop = _lib
      .lookupFunction<Uint32 Function(IntPtr), int Function(int)>('midiInStop');
  late final _close = _lib
      .lookupFunction<Uint32 Function(IntPtr), int Function(int)>(
        'midiInClose',
      );

  /// Names of the controllers now connected.
  List<String> devices() {
    if (!Platform.isWindows) return const [];
    final n = _numDevs();
    // MIDIINCAPSW: 2+2+4 bytes, 32 UTF-16 chars, 4 bytes
    final buf = calloc<Uint8>(76);
    try {
      return [
        for (var i = 0; i < n; i++)
          if (_caps(i, buf, 76) == 0) (buf + 8).cast<Utf16>().toDartString(),
      ];
    } finally {
      calloc.free(buf);
    }
  }

  /// Opens every controller; returns their names (throws when there are none).
  List<String> connect() {
    if (!Platform.isWindows) {
      throw StateError('MIDI controllers aren’t available here.');
    }
    final names = devices();
    if (names.isEmpty) {
      throw StateError('No MIDI controller found. Plug one in and try again.');
    }
    disconnect();
    _cb =
        NativeCallable<
          Void Function(IntPtr, Uint32, IntPtr, IntPtr, IntPtr)
        >.listener((int h, int msg, int inst, int p1, int p2) {
          if (msg != _mimData) return;
          final st = p1 & 0xf0,
              note = (p1 >> 8) & 0x7f,
              vel = (p1 >> 16) & 0x7f;
          if (st == 0x90 && vel > 0) {
            onNote?.call(note, true, vel / 127);
          } else if (st == 0x80 || (st == 0x90 && vel == 0)) {
            onNote?.call(note, false, 0);
          }
        });
    final out = calloc<IntPtr>();
    try {
      for (var i = 0; i < names.length; i++) {
        if (_open(out, i, _cb!.nativeFunction.address, 0, _callbackFunction) ==
            0) {
          _handles.add(out.value);
          _start(out.value);
        }
      }
    } finally {
      calloc.free(out);
    }
    if (_handles.isEmpty) {
      throw StateError('The MIDI controller is in use by another app.');
    }
    return names;
  }

  void disconnect() {
    for (final h in _handles) {
      _stop(h);
      _close(h);
    }
    _handles.clear();
    _cb?.close();
    _cb = null;
  }
}
