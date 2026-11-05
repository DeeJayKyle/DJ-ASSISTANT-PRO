// ONNX Runtime has no public accessor for a tensor's raw buffer; read it with
// the package's own generated bindings (copying 11M floats through nested
// lists would take longer than the model).
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

/// HTDemucs through ONNX Runtime on the processor (the Pro Stems AI pack's
/// `htdemucs_embedded.onnx`). Opened inside the isolate that runs it.
class HtDemucs {
  HtDemucs._(this._session);
  final OrtSession _session;

  static HtDemucs open(String modelPath) {
    OrtEnv.instance.init();
    final o = OrtSessionOptions()
      ..setIntraOpNumThreads(
        math.max(1, math.min(8, Platform.numberOfProcessors)),
      )
      ..setSessionGraphOptimizationLevel(GraphOptimizationLevel.ortEnableBasic);
    return HtDemucs._(OrtSession.fromFile(File(modelPath), o));
  }

  (Float32List?, Float32List) run(Float32List waveform, Float32List spec) {
    final names = _session.inputNames;
    final wave = OrtValueTensor.createTensorWithDataList(
      [waveform],
      [1, 2, seg],
    );
    final inputs = <String, OrtValue>{names[0]: wave};
    OrtValueTensor? sp;
    if (names.length > 1) {
      sp = OrtValueTensor.createTensorWithDataList(
        [spec],
        [1, 4, bins, frames],
      );
      inputs[names[1]] = sp;
    }
    final opts = OrtRunOptions();
    final outs = _session.run(opts, inputs);
    Float32List? time, freq;
    try {
      for (final v in outs) {
        if (v == null) continue;
        final (dims, data) = _tensor(v);
        if (dims.length == 4 && dims[2] == 2) {
          time = data;
        } else if (dims.length == 5 && dims[2] == 4) {
          freq = data;
        }
      }
    } finally {
      for (final v in outs) {
        v?.release();
      }
      wave.release();
      sp?.release();
      opts.release();
    }
    if (time == null) throw StateError('unexpected model output');
    return (freq, time);
  }

  void close() => _session.release();
}

(List<int>, Float32List) _tensor(OrtValue v) {
  final api = OrtEnv.instance.ortApiPtr.ref;
  final ptr = v.ptr;
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
