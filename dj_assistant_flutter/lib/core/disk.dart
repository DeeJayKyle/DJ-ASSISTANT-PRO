import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Free bytes available to this user on the drive holding [path], or null.
int? freeBytes(String path) {
  try {
    if (Platform.isWindows) {
      final k32 = DynamicLibrary.open('kernel32.dll');
      final fn = k32
          .lookupFunction<
            Int32 Function(
              Pointer<Utf16>,
              Pointer<Uint64>,
              Pointer<Uint64>,
              Pointer<Uint64>,
            ),
            int Function(
              Pointer<Utf16>,
              Pointer<Uint64>,
              Pointer<Uint64>,
              Pointer<Uint64>,
            )
          >('GetDiskFreeSpaceExW');
      final p = path.toNativeUtf16();
      final avail = calloc<Uint64>();
      try {
        return fn(p, avail, nullptr, nullptr) != 0 ? avail.value : null;
      } finally {
        calloc.free(p);
        calloc.free(avail);
      }
    }
    final r = Process.runSync('df', ['-Pk', path]);
    if (r.exitCode != 0) return null;
    final lines = (r.stdout as String).trim().split('\n');
    final cols = lines.last.split(RegExp(r'\s+'));
    return int.parse(cols[3]) * 1024;
  } on Exception {
    return null;
  }
}
