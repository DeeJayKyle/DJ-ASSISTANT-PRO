import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Physical memory this PC has free right now, in bytes, or null when it
/// can't be read (then nothing is refused on its account).
int? availableMemoryBytes() {
  try {
    if (Platform.isWindows) return _windows();
    if (Platform.isLinux) {
      final m = RegExp(r'MemAvailable:\s+(\d+) kB')
          .firstMatch(File('/proc/meminfo').readAsStringSync());
      return m == null ? null : int.parse(m.group(1)!) * 1024;
    }
  } on Object {
    return null;
  }
  return null;
}

// MEMORYSTATUSEX: dwLength, dwMemoryLoad, ullTotalPhys, ullAvailPhys, …
final class _MemStatus extends Struct {
  @Uint32()
  external int length;
  @Uint32()
  external int load;
  @Uint64()
  external int totalPhys;
  @Uint64()
  external int availPhys;
  @Uint64()
  external int totalPageFile;
  @Uint64()
  external int availPageFile;
  @Uint64()
  external int totalVirtual;
  @Uint64()
  external int availVirtual;
  @Uint64()
  external int availExtendedVirtual;
}

int? _windows() {
  final f = DynamicLibrary.open('kernel32.dll')
      .lookupFunction<
        Int32 Function(Pointer<_MemStatus>),
        int Function(Pointer<_MemStatus>)
      >('GlobalMemoryStatusEx');
  final p = calloc<_MemStatus>();
  try {
    p.ref.length = sizeOf<_MemStatus>();
    return f(p) == 0 ? null : p.ref.availPhys;
  } finally {
    calloc.free(p);
  }
}

String gb(int bytes) => (bytes / (1 << 30)).toStringAsFixed(1);
