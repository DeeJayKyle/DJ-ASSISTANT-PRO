import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'pcm.dart';

/// Decoding through Windows Media Foundation (`IMFSourceReader`), which ships with
/// Windows 10 and 11 and covers MP3, AAC/M4A, ALAC, WMA and the audio of MP4
/// videos. The reader is asked for 32-bit float PCM at the file's own sample rate
/// and channel count. Files are opened read-only by Media Foundation.
///
/// Vtable indices and GUIDs are taken from the Windows SDK headers
/// (mfreadwrite.h, mfobjects.h, mfapi.h).
class MediaFoundationReader implements PcmReader {
  MediaFoundationReader(String path) {
    // COM is per thread, and an isolate can run on any thread of Dart's pool:
    // initialise it for this reader (a decode runs synchronously on one
    // thread) and balance it in [close].
    _com = _Mf.instance.coInit();
    try {
      _Mf.instance.ensureStarted();
    } catch (_) {
      _uninit();
      rethrow;
    }
    final url = path.toNativeUtf16();
    final out = calloc<Pointer<Void>>();
    try {
      final hr = _Mf.instance.createSourceReaderFromUrl(url, nullptr, out);
      if (hr < 0) {
        _uninit();
        throw DecodeException(unsupportedMessage(path, hr));
      }
      _reader = out.value;
    } finally {
      calloc.free(url);
      calloc.free(out);
    }
    try {
      _configure();
    } catch (_) {
      _release(_reader);
      _uninit();
      rethrow;
    }
  }

  /// CoInitializeEx's result: S_OK or S_FALSE must be balanced.
  int _com = -1;
  void _uninit() {
    if (_com == 0 || _com == 1) _Mf.instance.coUninit();
    _com = -1;
  }

  late final Pointer<Void> _reader;
  int _rate = 0, _channels = 0;
  bool _closed = false;

  static const _firstAudio = 0xFFFFFFFD;
  static const _allStreams = 0xFFFFFFFE;
  static const _endOfStream = 0x2;
  static const _error = 0x1;

  @override
  int get sampleRate => _rate;
  @override
  int get channels => _channels;

  void _configure() {
    // Only the first audio stream; never decode video.
    _check(
      _fp(_reader, 4).cast<NativeFunction<_SetSel>>().asFunction<_SetSelD>()(
        _reader,
        _allStreams,
        0,
      ),
      'cannot select streams',
    );
    _check(
      _fp(_reader, 4).cast<NativeFunction<_SetSel>>().asFunction<_SetSelD>()(
        _reader,
        _firstAudio,
        1,
      ),
      'no audio track',
    );
    final mt = calloc<Pointer<Void>>();
    try {
      _check(_Mf.instance.createMediaType(mt), 'cannot create media type');
      final t = mt.value;
      try {
        _check(
          _fp(t, 24).cast<NativeFunction<_SetGuid>>().asFunction<_SetGuidD>()(
            t,
            _Guids.majorType,
            _Guids.audio,
          ),
          'media type',
        );
        _check(
          _fp(t, 24).cast<NativeFunction<_SetGuid>>().asFunction<_SetGuidD>()(
            t,
            _Guids.subtype,
            _Guids.float,
          ),
          'media type',
        );
        _check(
          _fp(_reader, 7)
              .cast<NativeFunction<_SetType>>()
              .asFunction<_SetTypeD>()(_reader, _firstAudio, nullptr, t),
          'no decoder for this codec',
        );
      } finally {
        _release(t);
      }
    } finally {
      calloc.free(mt);
    }
    _readFormat();
  }

  void _readFormat() {
    final mt = calloc<Pointer<Void>>();
    final v = calloc<Uint32>();
    try {
      _check(
        _fp(_reader, 6)
            .cast<NativeFunction<_GetType>>()
            .asFunction<_GetTypeD>()(_reader, _firstAudio, mt),
        'unknown audio format',
      );
      final t = mt.value;
      try {
        _check(
          _fp(t, 7).cast<NativeFunction<_GetU32>>().asFunction<_GetU32D>()(
            t,
            _Guids.channels,
            v,
          ),
          'unknown channel count',
        );
        _channels = v.value;
        _check(
          _fp(t, 7).cast<NativeFunction<_GetU32>>().asFunction<_GetU32D>()(
            t,
            _Guids.sampleRate,
            v,
          ),
          'unknown sample rate',
        );
        _rate = v.value;
      } finally {
        _release(t);
      }
    } finally {
      calloc.free(mt);
      calloc.free(v);
    }
    if (_channels < 1 || _rate < 1) {
      throw DecodeException('unsupported or damaged audio');
    }
  }

  @override
  Float32List? read() {
    if (_closed) return null;
    final actual = calloc<Uint32>();
    final flags = calloc<Uint32>();
    final ts = calloc<Int64>();
    final sample = calloc<Pointer<Void>>();
    try {
      while (true) {
        sample.value = nullptr;
        final hr =
            _fp(
              _reader,
              9,
            ).cast<NativeFunction<_ReadSample>>().asFunction<_ReadSampleD>()(
              _reader,
              _firstAudio,
              0,
              actual,
              flags,
              ts,
              sample,
            );
        if (hr < 0 || (flags.value & _error) != 0) {
          throw DecodeException(
            'could not decode audio (0x${(hr & 0xFFFFFFFF).toRadixString(16)})',
          );
        }
        if ((flags.value & 0x20) != 0) {
          _readFormat(); // format changed mid-stream
        }
        final s = sample.value;
        if (s == nullptr) {
          if ((flags.value & _endOfStream) != 0) return null;
          continue; // a gap; ask again
        }
        try {
          return _copy(s);
        } finally {
          _release(s);
        }
      }
    } finally {
      calloc.free(actual);
      calloc.free(flags);
      calloc.free(ts);
      calloc.free(sample);
    }
  }

  Float32List _copy(Pointer<Void> sample) {
    final buf = calloc<Pointer<Void>>();
    final data = calloc<Pointer<Uint8>>();
    final max = calloc<Uint32>();
    final cur = calloc<Uint32>();
    try {
      _check(
        _fp(sample, 41).cast<NativeFunction<_GetBuf>>().asFunction<_GetBufD>()(
          sample,
          buf,
        ),
        'cannot read decoded audio',
      );
      final b = buf.value;
      try {
        _check(
          _fp(b, 3).cast<NativeFunction<_Lock>>().asFunction<_LockD>()(
            b,
            data,
            max,
            cur,
          ),
          'cannot read decoded audio',
        );
        try {
          final n = cur.value ~/ 4;
          return Float32List.fromList(data.value.cast<Float>().asTypedList(n));
        } finally {
          _fp(b, 4).cast<NativeFunction<_Unlock>>().asFunction<_UnlockD>()(b);
        }
      } finally {
        _release(b);
      }
    } finally {
      calloc.free(buf);
      calloc.free(data);
      calloc.free(max);
      calloc.free(cur);
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _release(_reader);
    _uninit();
  }
}

/// Why Windows couldn't open [path]: for Ogg, Opus and WebM audio, the free
/// Microsoft codec that adds them (MF_E_UNSUPPORTED_BYTESTREAM_TYPE).
String unsupportedMessage(String path, int hr) {
  final code = (hr & 0xFFFFFFFF).toRadixString(16);
  final ext = path.split('.').last.toLowerCase();
  if ((hr & 0xFFFFFFFF) == 0xC00D36C4 &&
      const {'ogg', 'oga', 'opus', 'webm'}.contains(ext)) {
    return 'Windows needs Microsoft\'s free "Web Media Extensions" (Microsoft '
        'Store) to decode .$ext files. Install it, then press Re-check '
        'library or analyse again (0x$code)';
  }
  return 'cannot open this file (0x$code)';
}

void _check(int hr, String what) {
  if (hr < 0) {
    throw DecodeException('$what (0x${(hr & 0xFFFFFFFF).toRadixString(16)})');
  }
}

/// Function [index] of a COM object's vtable.
Pointer<Void> _fp(Pointer<Void> obj, int index) =>
    obj.cast<Pointer<Pointer<Void>>>().value[index];

void _release(Pointer<Void> obj) {
  if (obj != nullptr) {
    _fp(obj, 2).cast<NativeFunction<_Release>>().asFunction<_ReleaseD>()(obj);
  }
}

typedef _Unlock = Int32 Function(Pointer<Void>);
typedef _UnlockD = int Function(Pointer<Void>);
typedef _Release = Uint32 Function(Pointer<Void>);
typedef _ReleaseD = int Function(Pointer<Void>);
typedef _SetSel = Int32 Function(Pointer<Void>, Uint32, Int32);
typedef _SetSelD = int Function(Pointer<Void>, int, int);
typedef _SetType = Int32 Function(
  Pointer<Void>,
  Uint32,
  Pointer<Uint32>,
  Pointer<Void>,
);
typedef _SetTypeD = int Function(
  Pointer<Void>,
  int,
  Pointer<Uint32>,
  Pointer<Void>,
);
typedef _GetType = Int32 Function(
  Pointer<Void>,
  Uint32,
  Pointer<Pointer<Void>>,
);
typedef _GetTypeD = int Function(Pointer<Void>, int, Pointer<Pointer<Void>>);
typedef _SetGuid = Int32 Function(
  Pointer<Void>,
  Pointer<Uint8>,
  Pointer<Uint8>,
);
typedef _SetGuidD = int Function(Pointer<Void>, Pointer<Uint8>, Pointer<Uint8>);
typedef _GetU32 = Int32 Function(
  Pointer<Void>,
  Pointer<Uint8>,
  Pointer<Uint32>,
);
typedef _GetU32D = int Function(Pointer<Void>, Pointer<Uint8>, Pointer<Uint32>);
typedef _ReadSample = Int32 Function(
  Pointer<Void>,
  Uint32,
  Uint32,
  Pointer<Uint32>,
  Pointer<Uint32>,
  Pointer<Int64>,
  Pointer<Pointer<Void>>,
);
typedef _ReadSampleD = int Function(
  Pointer<Void>,
  int,
  int,
  Pointer<Uint32>,
  Pointer<Uint32>,
  Pointer<Int64>,
  Pointer<Pointer<Void>>,
);
typedef _GetBuf = Int32 Function(Pointer<Void>, Pointer<Pointer<Void>>);
typedef _GetBufD = int Function(Pointer<Void>, Pointer<Pointer<Void>>);
typedef _Lock = Int32 Function(
  Pointer<Void>,
  Pointer<Pointer<Uint8>>,
  Pointer<Uint32>,
  Pointer<Uint32>,
);
typedef _LockD = int Function(
  Pointer<Void>,
  Pointer<Pointer<Uint8>>,
  Pointer<Uint32>,
  Pointer<Uint32>,
);

/// GUIDs from mfapi.h, laid out as in memory (Data1–3 little-endian).
class _Guids {
  static final majorType = _guid(0x48eba18e, 0xf8c9, 0x4687, [
    0xbf,
    0x11,
    0x0a,
    0x74,
    0xc9,
    0xf9,
    0x6a,
    0x8f,
  ]);
  static final subtype = _guid(0xf7e34c9a, 0x42e8, 0x4714, [
    0xb7,
    0x4b,
    0xcb,
    0x29,
    0xd7,
    0x2c,
    0x35,
    0xe5,
  ]);
  static final audio = _guid(0x73647561, 0x0000, 0x0010, _mediaTail);
  static final float = _guid(0x00000003, 0x0000, 0x0010, _mediaTail);
  static final channels = _guid(0x37e48bf5, 0x645e, 0x4c5b, [
    0x89,
    0xde,
    0xad,
    0xa9,
    0xe2,
    0x9b,
    0x69,
    0x6a,
  ]);
  static final sampleRate = _guid(0x5faeeae7, 0x0290, 0x4c31, [
    0x9e,
    0x8a,
    0xc5,
    0x34,
    0xf6,
    0x8d,
    0x9d,
    0xba,
  ]);
  static const _mediaTail = [0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71];
}

/// A GUID in native memory, kept for the life of the process.
Pointer<Uint8> _guid(int d1, int d2, int d3, List<int> d4) {
  final p = malloc<Uint8>(16);
  final b = ByteData(16)
    ..setUint32(0, d1, Endian.little)
    ..setUint16(4, d2, Endian.little)
    ..setUint16(6, d3, Endian.little);
  for (var i = 0; i < 8; i++) {
    b.setUint8(8 + i, d4[i]);
  }
  p.asTypedList(16).setAll(0, b.buffer.asUint8List());
  return p;
}

/// Media Foundation entry points, loaded on first use (Windows only).
class _Mf {
  _Mf._() {
    final ole = DynamicLibrary.open('ole32.dll');
    final plat = DynamicLibrary.open('mfplat.dll');
    final rw = DynamicLibrary.open('mfreadwrite.dll');
    _coInit = ole
        .lookupFunction<
          Int32 Function(Pointer<Void>, Uint32),
          int Function(Pointer<Void>, int)
        >('CoInitializeEx');
    _coUninit = ole.lookupFunction<Void Function(), void Function()>(
      'CoUninitialize',
    );
    _startup = plat
        .lookupFunction<Int32 Function(Uint32, Uint32), int Function(int, int)>(
          'MFStartup',
        );
    createMediaType = plat
        .lookupFunction<
          Int32 Function(Pointer<Pointer<Void>>),
          int Function(Pointer<Pointer<Void>>)
        >('MFCreateMediaType');
    createSourceReaderFromUrl = rw
        .lookupFunction<
          Int32 Function(Pointer<Utf16>, Pointer<Void>, Pointer<Pointer<Void>>),
          int Function(Pointer<Utf16>, Pointer<Void>, Pointer<Pointer<Void>>)
        >('MFCreateSourceReaderFromURL');
  }

  static final instance = _Mf._();

  late final int Function(Pointer<Void>, int) _coInit;
  late final void Function() _coUninit;
  late final int Function(int, int) _startup;

  /// COINIT_MULTITHREADED on the calling thread. S_FALSE: already
  /// initialised; RPC_E_CHANGED_MODE: an STA thread (still usable).
  int coInit() => _coInit(nullptr, 0);
  void coUninit() => _coUninit();
  late final int Function(Pointer<Pointer<Void>>) createMediaType;
  late final int Function(Pointer<Utf16>, Pointer<Void>, Pointer<Pointer<Void>>)
  createSourceReaderFromUrl;
  bool _started = false;

  void ensureStarted() {
    if (_started) return;
    _check(
      _startup(0x00020070, 0),
      'Media Foundation is not available on this PC',
    );
    _started = true;
  }
}
