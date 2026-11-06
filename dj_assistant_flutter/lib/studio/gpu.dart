import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// The graphics card DirectML would use (DXGI adapter 0), or null when there
/// is none worth using: off Windows, or only Microsoft's software renderer
/// (virtual machines, CI, PCs without a driver), which is far slower than
/// the processor for Pro Stems AI.
String? hardwareGpu() {
  if (!Platform.isWindows) return null;
  try {
    return _adapter0();
  } on Object {
    return null;
  }
}

typedef _CreateFactory = Int32 Function(Pointer<Uint8>, Pointer<Pointer<Void>>);
typedef _CreateFactoryD = int Function(Pointer<Uint8>, Pointer<Pointer<Void>>);
typedef _Enum = Int32 Function(Pointer<Void>, Uint32, Pointer<Pointer<Void>>);
typedef _EnumD = int Function(Pointer<Void>, int, Pointer<Pointer<Void>>);
typedef _Desc = Int32 Function(Pointer<Void>, Pointer<Uint8>);
typedef _DescD = int Function(Pointer<Void>, Pointer<Uint8>);
typedef _Release = Uint32 Function(Pointer<Void>);
typedef _ReleaseD = int Function(Pointer<Void>);

Pointer<Void> _fn(Pointer<Void> obj, int i) =>
    obj.cast<Pointer<Pointer<Void>>>().value[i];
void _release(Pointer<Void> o) =>
    _fn(o, 2).cast<NativeFunction<_Release>>().asFunction<_ReleaseD>()(o);

String? _adapter0() {
  final create = DynamicLibrary.open('dxgi.dll')
      .lookupFunction<_CreateFactory, _CreateFactoryD>('CreateDXGIFactory1');
  // IID_IDXGIFactory1 {770aae78-f26f-4dba-a829-253c83d1b387}
  final iid = calloc<Uint8>(16);
  final b = ByteData(16)
    ..setUint32(0, 0x770aae78, Endian.little)
    ..setUint16(4, 0xf26f, Endian.little)
    ..setUint16(6, 0x4dba, Endian.little);
  const tail = [0xa8, 0x29, 0x25, 0x3c, 0x83, 0xd1, 0xb3, 0x87];
  for (var i = 0; i < 8; i++) {
    b.setUint8(8 + i, tail[i]);
  }
  iid.asTypedList(16).setAll(0, b.buffer.asUint8List());
  final pf = calloc<Pointer<Void>>(), pa = calloc<Pointer<Void>>();
  final desc = calloc<Uint8>(_descSize);
  try {
    if (create(iid, pf) < 0) return null;
    final f = pf.value;
    try {
      // IDXGIFactory1::EnumAdapters1 (vtable 12)
      final hr = _fn(f, 12).cast<NativeFunction<_Enum>>().asFunction<_EnumD>()(
        f,
        0,
        pa,
      );
      if (hr < 0) return null;
      final a = pa.value;
      try {
        // IDXGIAdapter1::GetDesc1 (vtable 10)
        if (_fn(a, 10).cast<NativeFunction<_Desc>>().asFunction<_DescD>()(
              a,
              desc,
            ) <
            0) {
          return null;
        }
        return describe(desc.asTypedList(_descSize));
      } finally {
        _release(a);
      }
    } finally {
      _release(f);
    }
  } finally {
    calloc
      ..free(iid)
      ..free(pf)
      ..free(pa)
      ..free(desc);
  }
}

const _descSize = 312;

/// Reads a DXGI_ADAPTER_DESC1: the adapter's name, or null for a software
/// adapter (DXGI_ADAPTER_FLAG_SOFTWARE, or the Microsoft Basic Render Driver).
String? describe(Uint8List d) {
  final v = ByteData.sublistView(d);
  final vendor = v.getUint32(256, Endian.little);
  final device = v.getUint32(260, Endian.little);
  final flags = v.getUint32(304, Endian.little);
  if (flags & 2 != 0) return null;
  if (vendor == 0x1414 && (device == 0x8c || device == 0x8e)) return null;
  final name = StringBuffer();
  for (var i = 0; i < 128; i++) {
    final c = v.getUint16(i * 2, Endian.little);
    if (c == 0) break;
    name.writeCharCode(c);
  }
  final s = name.toString().trim();
  return s.isEmpty ? 'graphics card' : s;
}
