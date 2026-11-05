import 'dart:io';
import 'dart:typed_data';

import 'flac.dart';
import 'media_foundation.dart';
import 'pcm_files.dart';

/// Decoded audio, read in blocks of interleaved 32-bit float samples in −1…1.
/// Readers only ever open files for reading.
abstract class PcmReader {
  int get sampleRate;
  int get channels;

  /// The next block of interleaved samples, or null at the end.
  Float32List? read();

  void close();
}

class DecodeException implements Exception {
  DecodeException(this.message);
  final String message;
  @override
  String toString() => message;
}

String _magic(String path) {
  try {
    final f = File(path).openSync();
    try {
      return String.fromCharCodes(
        f.readSync(12).map((b) => b < 32 || b > 126 ? 46 : b),
      );
    } finally {
      f.closeSync();
    }
  } on FileSystemException catch (e) {
    throw DecodeException('cannot open: ${e.message}');
  }
}

/// Opens [path] for decoding. WAV, AIFF and FLAC are decoded in Dart on every
/// platform; everything else (MP3, AAC/M4A, ALAC, WMA…) through Windows Media
/// Foundation, which ships with Windows 10 and 11.
PcmReader openPcm(String path) {
  final m = _magic(path);
  if (m.startsWith('RIFF') && m.substring(8) == 'WAVE') return WavReader(path);
  if (m.startsWith('FORM') &&
      (m.substring(8) == 'AIFF' || m.substring(8) == 'AIFC')) {
    return AiffReader(path);
  }
  if (m.startsWith('fLaC') ||
      (m.startsWith('ID3') && FlacReader.hasFlacAfterId3(path))) {
    return FlacReader(path);
  }
  if (Platform.isWindows) return MediaFoundationReader(path);
  throw DecodeException('this format can only be decoded on Windows');
}
