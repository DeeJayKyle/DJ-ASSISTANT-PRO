// The onnxruntime package's session API can't pick an execution provider and
// passes the model path as UTF-8, which Windows' wide-character API misreads;
// tensors built from Dart lists also copy ~3M values per segment. This calls
// ONNX Runtime's C API directly, with the package's generated bindings.
// ignore_for_file: implementation_imports
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:onnxruntime/onnxruntime.dart';
import 'package:onnxruntime/src/bindings/onnxruntime_bindings_generated.dart'
    as bg;

import 'ai_stems.dart';
import 'gpu.dart';

typedef _AppendDml = bg.OrtStatusPtr Function(
  ffi.Pointer<bg.OrtSessionOptions>,
  ffi.Int32,
);
typedef _AppendDmlD = bg.OrtStatusPtr Function(
  ffi.Pointer<bg.OrtSessionOptions>,
  int,
);

/// HTDemucs through ONNX Runtime (the Pro Stems AI pack's
/// `htdemucs_embedded.onnx`). Opened inside the isolate that runs it.
///
/// On Windows it runs on the graphics card with DirectML when it can, and on
/// the processor otherwise ([device] says which).
class HtDemucs {
  HtDemucs._(this._session, this.device, this.inputNames, this.outputNames) {
    _wave = calloc<ffi.Float>(2 * seg);
    _spec = calloc<ffi.Float>(4 * bins * frames);
    final mi = calloc<ffi.Pointer<bg.OrtMemoryInfo>>();
    try {
      _check(
        _api.CreateCpuMemoryInfo.asFunction<
          bg.OrtStatusPtr Function(
            int,
            int,
            ffi.Pointer<ffi.Pointer<bg.OrtMemoryInfo>>,
          )
        >()(
          bg.OrtAllocatorType.OrtDeviceAllocator,
          bg.OrtMemType.OrtMemTypeDefault,
          mi,
        ),
      );
      _mem = mi.value;
    } finally {
      calloc.free(mi);
    }
    _inNames = _cStrings(inputNames);
    _outNames = _cStrings(outputNames);
  }

  final ffi.Pointer<bg.OrtSession> _session;

  /// 'gpu' (DirectML) or 'cpu'.
  final String device;

  /// The graphics card's name when [device] is 'gpu'.
  String? gpuName;
  final List<String> inputNames, outputNames;
  late final ffi.Pointer<ffi.Float> _wave, _spec;
  late final ffi.Pointer<bg.OrtMemoryInfo> _mem;
  late final ffi.Pointer<ffi.Pointer<ffi.Char>> _inNames, _outNames;
  bool _closed = false;

  static bg.OrtApi get _api => OrtEnv.instance.ortApiPtr.ref;

  /// Opens [modelPath]; with [gpu], uses DirectML when there is a hardware
  /// graphics card, falling back to the processor if it can't run the model.
  static HtDemucs open(String modelPath, {bool gpu = true}) {
    OrtEnv.instance.init();
    if (!File(modelPath).existsSync()) {
      throw StateError('the model file is missing ($modelPath)');
    }
    final card = gpu ? hardwareGpu() : null;
    if (card != null) {
      try {
        return _open(modelPath, dml: true)..gpuName = card;
      } on Object {
        // the driver can't run this model: use the processor
      }
    }
    return _open(modelPath, dml: false);
  }

  static HtDemucs _open(String modelPath, {required bool dml}) {
    final api = _api;
    final op = calloc<ffi.Pointer<bg.OrtSessionOptions>>();
    _check(
      api.CreateSessionOptions.asFunction<
        bg.OrtStatusPtr Function(ffi.Pointer<ffi.Pointer<bg.OrtSessionOptions>>)
      >()(op),
    );
    final o = op.value;
    calloc.free(op);
    final path = Platform.isWindows
        ? modelPath.toNativeUtf16().cast<ffi.Char>()
        : modelPath.toNativeUtf8().cast<ffi.Char>();
    final sp = calloc<ffi.Pointer<bg.OrtSession>>();
    try {
      _check(
        api.SetIntraOpNumThreads.asFunction<
          bg.OrtStatusPtr Function(ffi.Pointer<bg.OrtSessionOptions>, int)
        >()(o, math.max(1, math.min(8, Platform.numberOfProcessors))),
      );
      _check(
        api.SetSessionGraphOptimizationLevel.asFunction<
          bg.OrtStatusPtr Function(ffi.Pointer<bg.OrtSessionOptions>, int)
        >()(o, bg.GraphOptimizationLevel.ORT_ENABLE_BASIC),
      );
      if (dml) {
        // DirectML needs sequential execution without memory patterns.
        _check(
          api.DisableMemPattern.asFunction<
            bg.OrtStatusPtr Function(ffi.Pointer<bg.OrtSessionOptions>)
          >()(o),
        );
        _check(
          api.SetSessionExecutionMode.asFunction<
            bg.OrtStatusPtr Function(ffi.Pointer<bg.OrtSessionOptions>, int)
          >()(o, bg.ExecutionMode.ORT_SEQUENTIAL),
        );
        final append = ffi.DynamicLibrary.open('onnxruntime.dll')
            .lookupFunction<_AppendDml, _AppendDmlD>(
              'OrtSessionOptionsAppendExecutionProvider_DML',
            );
        _check(append(o, 0));
      }
      _check(
        api.CreateSession.asFunction<
          bg.OrtStatusPtr Function(
            ffi.Pointer<bg.OrtEnv>,
            ffi.Pointer<ffi.Char>,
            ffi.Pointer<bg.OrtSessionOptions>,
            ffi.Pointer<ffi.Pointer<bg.OrtSession>>,
          )
        >()(OrtEnv.instance.ptr, path, o, sp),
      );
      final s = sp.value;
      return HtDemucs._(
        s,
        dml ? 'gpu' : 'cpu',
        _names(s, input: true),
        _names(s, input: false),
      );
    } finally {
      calloc
        ..free(path)
        ..free(sp);
      api.ReleaseSessionOptions.asFunction<
        void Function(ffi.Pointer<bg.OrtSessionOptions>)
      >()(o);
    }
  }

  static List<String> _names(
    ffi.Pointer<bg.OrtSession> s, {
    required bool input,
  }) {
    final api = _api;
    final n = calloc<ffi.Size>();
    final name = calloc<ffi.Pointer<ffi.Char>>();
    final alloc = OrtAllocator.instance.ptr;
    try {
      _check(
        (input ? api.SessionGetInputCount : api.SessionGetOutputCount)
            .asFunction<
              bg.OrtStatusPtr Function(
                ffi.Pointer<bg.OrtSession>,
                ffi.Pointer<ffi.Size>,
              )
            >()(s, n),
      );
      return [
        for (var i = 0; i < n.value; i++)
          () {
            _check(
              (input ? api.SessionGetInputName : api.SessionGetOutputName)
                  .asFunction<
                    bg.OrtStatusPtr Function(
                      ffi.Pointer<bg.OrtSession>,
                      int,
                      ffi.Pointer<bg.OrtAllocator>,
                      ffi.Pointer<ffi.Pointer<ffi.Char>>,
                    )
                  >()(s, i, alloc, name),
            );
            final v = name.value.cast<Utf8>().toDartString();
            _check(
              api.AllocatorFree.asFunction<
                bg.OrtStatusPtr Function(
                  ffi.Pointer<bg.OrtAllocator>,
                  ffi.Pointer<ffi.Void>,
                )
              >()(alloc, name.value.cast()),
            );
            return v;
          }(),
      ];
    } finally {
      calloc
        ..free(n)
        ..free(name);
    }
  }

  static ffi.Pointer<ffi.Pointer<ffi.Char>> _cStrings(List<String> xs) {
    final p = calloc<ffi.Pointer<ffi.Char>>(xs.length);
    for (var i = 0; i < xs.length; i++) {
      p[i] = xs[i].toNativeUtf8().cast();
    }
    return p;
  }

  ffi.Pointer<bg.OrtValue> _tensorOver(
    ffi.Pointer<ffi.Float> data,
    int count,
    List<int> shape,
  ) {
    final dims = calloc<ffi.Int64>(shape.length);
    final out = calloc<ffi.Pointer<bg.OrtValue>>();
    try {
      for (var i = 0; i < shape.length; i++) {
        dims[i] = shape[i];
      }
      _check(
        _api.CreateTensorWithDataAsOrtValue.asFunction<
          bg.OrtStatusPtr Function(
            ffi.Pointer<bg.OrtMemoryInfo>,
            ffi.Pointer<ffi.Void>,
            int,
            ffi.Pointer<ffi.Int64>,
            int,
            int,
            ffi.Pointer<ffi.Pointer<bg.OrtValue>>,
          )
        >()(
          _mem,
          data.cast(),
          count * 4,
          dims,
          shape.length,
          bg.ONNXTensorElementDataType.ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT,
          out,
        ),
      );
      return out.value;
    } finally {
      calloc
        ..free(dims)
        ..free(out);
    }
  }

  static void _release(ffi.Pointer<bg.OrtValue> v) {
    if (v == ffi.nullptr) return;
    _api.ReleaseValue.asFunction<void Function(ffi.Pointer<bg.OrtValue>)>()(v);
  }

  /// One segment: (freq [4×4×BINS×FRAMES] or null, time [4×2×SEG]).
  (Float32List?, Float32List) run(Float32List waveform, Float32List spec) {
    if (_closed) throw StateError('the model is closed');
    _wave.asTypedList(2 * seg).setAll(0, waveform);
    final two = inputNames.length > 1;
    if (two) _spec.asTypedList(4 * bins * frames).setAll(0, spec);
    final ins = calloc<ffi.Pointer<bg.OrtValue>>(2);
    final outs = calloc<ffi.Pointer<bg.OrtValue>>(outputNames.length);
    try {
      ins[0] = _tensorOver(_wave, 2 * seg, [1, 2, seg]);
      if (two) {
        ins[1] = _tensorOver(_spec, 4 * bins * frames, [1, 4, bins, frames]);
      }
      _check(
        _api.Run.asFunction<
          bg.OrtStatusPtr Function(
            ffi.Pointer<bg.OrtSession>,
            ffi.Pointer<bg.OrtRunOptions>,
            ffi.Pointer<ffi.Pointer<ffi.Char>>,
            ffi.Pointer<ffi.Pointer<bg.OrtValue>>,
            int,
            ffi.Pointer<ffi.Pointer<ffi.Char>>,
            int,
            ffi.Pointer<ffi.Pointer<bg.OrtValue>>,
          )
        >()(
          _session,
          ffi.nullptr,
          _inNames,
          ins,
          two ? 2 : 1,
          _outNames,
          outputNames.length,
          outs,
        ),
      );
      Float32List? time, freq;
      for (var k = 0; k < outputNames.length; k++) {
        if (outs[k] == ffi.nullptr) continue;
        final (dims, data) = _tensor(outs[k]);
        if (dims.length == 4 && dims[2] == 2) {
          time = data;
        } else if (dims.length == 5 && dims[2] == 4) {
          freq = data;
        }
      }
      if (time == null) {
        throw StateError('unexpected model outputs ${outputNames.join(', ')}');
      }
      return (freq, time);
    } finally {
      for (var k = 0; k < outputNames.length; k++) {
        _release(outs[k]);
      }
      _release(ins[0]);
      if (two) _release(ins[1]);
      calloc
        ..free(ins)
        ..free(outs);
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _api.ReleaseSession.asFunction<void Function(ffi.Pointer<bg.OrtSession>)>()(
      _session,
    );
    _api.ReleaseMemoryInfo.asFunction<
      void Function(ffi.Pointer<bg.OrtMemoryInfo>)
    >()(_mem);
    for (final (p, n) in [
      (_inNames, inputNames.length),
      (_outNames, outputNames.length),
    ]) {
      for (var i = 0; i < n; i++) {
        calloc.free(p[i]);
      }
      calloc.free(p);
    }
    calloc
      ..free(_wave)
      ..free(_spec);
  }
}

(List<int>, Float32List) _tensor(ffi.Pointer<bg.OrtValue> ptr) {
  final api = OrtEnv.instance.ortApiPtr.ref;
  final info = calloc<ffi.Pointer<bg.OrtTensorTypeAndShapeInfo>>();
  final count = calloc<ffi.Size>();
  final nd = calloc<ffi.Size>();
  final data = calloc<ffi.Pointer<ffi.Void>>();
  try {
    _check(
      api.GetTensorTypeAndShape.asFunction<
        bg.OrtStatusPtr Function(
          ffi.Pointer<bg.OrtValue>,
          ffi.Pointer<ffi.Pointer<bg.OrtTensorTypeAndShapeInfo>>,
        )
      >()(ptr, info),
    );
    final i = info.value;
    try {
      _check(
        api.GetDimensionsCount.asFunction<
          bg.OrtStatusPtr Function(
            ffi.Pointer<bg.OrtTensorTypeAndShapeInfo>,
            ffi.Pointer<ffi.Size>,
          )
        >()(i, nd),
      );
      final dims = calloc<ffi.Int64>(nd.value);
      try {
        _check(
          api.GetDimensions.asFunction<
            bg.OrtStatusPtr Function(
              ffi.Pointer<bg.OrtTensorTypeAndShapeInfo>,
              ffi.Pointer<ffi.Int64>,
              int,
            )
          >()(i, dims, nd.value),
        );
        _check(
          api.GetTensorShapeElementCount.asFunction<
            bg.OrtStatusPtr Function(
              ffi.Pointer<bg.OrtTensorTypeAndShapeInfo>,
              ffi.Pointer<ffi.Size>,
            )
          >()(i, count),
        );
        _check(
          api.GetTensorMutableData.asFunction<
            bg.OrtStatusPtr Function(
              ffi.Pointer<bg.OrtValue>,
              ffi.Pointer<ffi.Pointer<ffi.Void>>,
            )
          >()(ptr, data),
        );
        final shape = [for (var k = 0; k < nd.value; k++) dims[k]];
        final floats = Float32List.fromList(
          data.value.cast<ffi.Float>().asTypedList(count.value),
        );
        return (shape, floats);
      } finally {
        calloc.free(dims);
      }
    } finally {
      api.ReleaseTensorTypeAndShapeInfo.asFunction<
        void Function(ffi.Pointer<bg.OrtTensorTypeAndShapeInfo>)
      >()(i);
    }
  } finally {
    calloc
      ..free(info)
      ..free(count)
      ..free(nd)
      ..free(data);
  }
}

void _check(bg.OrtStatusPtr s) => OrtStatus.checkOrtStatus(s);
