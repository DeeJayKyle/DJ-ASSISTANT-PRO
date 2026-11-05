import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'online.dart';

// CREDENTIALW (wincred.h). Dart lays the fields out with the C alignment rules.
final class _Credential extends Struct {
  @Uint32()
  external int flags;
  @Uint32()
  external int type;
  external Pointer<Utf16> targetName;
  external Pointer<Utf16> comment;
  @Uint32()
  external int lastWrittenLow;
  @Uint32()
  external int lastWrittenHigh;
  @Uint32()
  external int credentialBlobSize;
  external Pointer<Uint8> credentialBlob;
  @Uint32()
  external int persist;
  @Uint32()
  external int attributeCount;
  external Pointer<Void> attributes;
  external Pointer<Utf16> targetAlias;
  external Pointer<Utf16> userName;
}

const _credTypeGeneric = 1;
const _credPersistEnterprise = 3;
const _errorNotFound = 1168;

/// Windows Credential Manager, in the format DJ Assistant 1.x wrote (the
/// `keyring` crate): a generic credential named "`<service>.DJ Assistant`",
/// user name = service, the secret as UTF-16LE without a terminator. Keys saved
/// by 1.8 are found by 2.0 and the other way round.
class WindowsSecrets implements Secrets {
  WindowsSecrets() : _lib = DynamicLibrary.open('advapi32.dll');
  final DynamicLibrary _lib;

  static String target(String service) => '$service.DJ Assistant';

  late final _read = _lib
      .lookupFunction<
        Int32 Function(
          Pointer<Utf16>,
          Uint32,
          Uint32,
          Pointer<Pointer<_Credential>>,
        ),
        int Function(Pointer<Utf16>, int, int, Pointer<Pointer<_Credential>>)
      >('CredReadW');
  late final _write = _lib
      .lookupFunction<
        Int32 Function(Pointer<_Credential>, Uint32),
        int Function(Pointer<_Credential>, int)
      >('CredWriteW');
  late final _delete = _lib
      .lookupFunction<
        Int32 Function(Pointer<Utf16>, Uint32, Uint32),
        int Function(Pointer<Utf16>, int, int)
      >('CredDeleteW');
  late final _free = _lib
      .lookupFunction<Void Function(Pointer), void Function(Pointer)>(
        'CredFree',
      );
  late final _lastError = DynamicLibrary.open('kernel32.dll')
      .lookupFunction<Uint32 Function(), int Function()>('GetLastError');

  @override
  String? get(String service) {
    final name = target(service).toNativeUtf16();
    final out = calloc<Pointer<_Credential>>();
    try {
      if (_read(name, _credTypeGeneric, 0, out) == 0) return null;
      final c = out.value.ref;
      final n = c.credentialBlobSize;
      final bytes = Uint8List.fromList(c.credentialBlob.asTypedList(n));
      _free(out.value);
      if (n.isOdd) return null;
      final units = Uint16List(n ~/ 2);
      final view = ByteData.sublistView(bytes);
      for (var i = 0; i < units.length; i++) {
        units[i] = view.getUint16(i * 2, Endian.little);
      }
      return String.fromCharCodes(units);
    } finally {
      calloc
        ..free(name)
        ..free(out);
    }
  }

  @override
  void set(String service, String value) {
    final units = value.codeUnits;
    final blob = calloc<Uint8>(units.length * 2 + 1);
    for (var i = 0; i < units.length; i++) {
      blob[i * 2] = units[i] & 0xff;
      blob[i * 2 + 1] = units[i] >> 8;
    }
    final name = target(service).toNativeUtf16();
    final user = service.toNativeUtf16();
    final comment = 'DJ Assistant'.toNativeUtf16();
    final cred = calloc<_Credential>();
    cred.ref
      ..flags = 0
      ..type = _credTypeGeneric
      ..targetName = name
      ..comment = comment
      ..credentialBlobSize = units.length * 2
      ..credentialBlob = blob
      ..persist = _credPersistEnterprise
      ..attributeCount = 0
      ..attributes = nullptr
      ..targetAlias = nullptr
      ..userName = user;
    try {
      if (_write(cred, 0) == 0) {
        throw OnlineException(
          "couldn't save the key in Windows Credential Manager "
          '(error ${_lastError()})',
        );
      }
    } finally {
      // Wipe the copy of the secret before freeing it.
      for (var i = 0; i < units.length * 2; i++) {
        blob[i] = 0;
      }
      calloc
        ..free(blob)
        ..free(name)
        ..free(user)
        ..free(comment)
        ..free(cred);
    }
  }

  @override
  void delete(String service) {
    // GetLastError is not reliable from Dart, so check for "not found" first.
    if (get(service) == null) return;
    final name = target(service).toNativeUtf16();
    try {
      if (_delete(name, _credTypeGeneric, 0) == 0 &&
          _lastError() != _errorNotFound) {
        throw OnlineException(
          "couldn't remove the key from Windows Credential Manager",
        );
      }
    } finally {
      calloc.free(name);
    }
  }
}

/// The platform's secret store: Credential Manager on Windows, memory elsewhere
/// (development builds on Linux keep keys for the session only).
Secrets platformSecrets() =>
    Platform.isWindows ? WindowsSecrets() : MemorySecrets();
