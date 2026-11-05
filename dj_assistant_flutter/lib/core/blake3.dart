import 'dart:io';
import 'dart:typed_data';

/// BLAKE3 (default hash mode, 256-bit output), as 1.x uses for file hashes
/// (change log, duplicate detection). Written from the specification; checked
/// against the reference test vectors and against 1.x on real files.
const _iv = [
  0x6A09E667,
  0xBB67AE85,
  0x3C6EF372,
  0xA54FF53A,
  0x510E527F,
  0x9B05688C,
  0x1F83D9AB,
  0x5BE0CD19,
];
const _perm = [2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8];
const _chunkStart = 1, _chunkEnd = 2, _parent = 4, _root = 8;
const _blockLen = 64, _chunkLen = 1024;

int _rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & 0xFFFFFFFF;

final _state = Uint32List(16);
final _m = Uint32List(16);
final _tmp = Uint32List(16);

void _g(Uint32List s, int a, int b, int c, int d, int x, int y) {
  s[a] = s[a] + s[b] + x;
  s[d] = _rotr(s[d] ^ s[a], 16);
  s[c] = s[c] + s[d];
  s[b] = _rotr(s[b] ^ s[c], 12);
  s[a] = s[a] + s[b] + y;
  s[d] = _rotr(s[d] ^ s[a], 8);
  s[c] = s[c] + s[d];
  s[b] = _rotr(s[b] ^ s[c], 7);
}

/// The compression function; returns all 16 output words.
Uint32List _compress(
  Uint32List cv,
  Uint32List block,
  int counter,
  int len,
  int flags,
) {
  final s = _state, m = _m;
  for (var i = 0; i < 8; i++) {
    s[i] = cv[i];
  }
  s[8] = _iv[0];
  s[9] = _iv[1];
  s[10] = _iv[2];
  s[11] = _iv[3];
  s[12] = counter & 0xFFFFFFFF;
  s[13] = (counter >> 32) & 0xFFFFFFFF;
  s[14] = len;
  s[15] = flags;
  m.setAll(0, block);
  for (var r = 0; r < 7; r++) {
    _g(s, 0, 4, 8, 12, m[0], m[1]);
    _g(s, 1, 5, 9, 13, m[2], m[3]);
    _g(s, 2, 6, 10, 14, m[4], m[5]);
    _g(s, 3, 7, 11, 15, m[6], m[7]);
    _g(s, 0, 5, 10, 15, m[8], m[9]);
    _g(s, 1, 6, 11, 12, m[10], m[11]);
    _g(s, 2, 7, 8, 13, m[12], m[13]);
    _g(s, 3, 4, 9, 14, m[14], m[15]);
    if (r < 6) {
      for (var i = 0; i < 16; i++) {
        _tmp[i] = m[_perm[i]];
      }
      m.setAll(0, _tmp);
    }
  }
  final out = Uint32List(16);
  for (var i = 0; i < 8; i++) {
    out[i] = s[i] ^ s[i + 8];
    out[i + 8] = s[i + 8] ^ cv[i];
  }
  return out;
}

class _Output {
  _Output(this.cv, this.block, this.counter, this.len, this.flags);
  final Uint32List cv, block;
  final int counter, len, flags;
  Uint32List chaining() =>
      Uint32List.sublistView(_compress(cv, block, counter, len, flags), 0, 8);
  Uint8List root() {
    final w = _compress(cv, block, 0, len, flags | _root);
    final b = ByteData(32);
    for (var i = 0; i < 8; i++) {
      b.setUint32(i * 4, w[i], Endian.little);
    }
    return b.buffer.asUint8List();
  }
}

/// Incremental BLAKE3 hasher.
class Blake3 {
  final _key = Uint32List.fromList(_iv);
  final _stack = <Uint32List>[];
  var _cv = Uint32List.fromList(_iv);
  var _chunkCounter = 0;
  final _buf = Uint8List(_blockLen);
  var _bufLen = 0;
  var _blocksCompressed = 0;
  final _words = Uint32List(16);

  Uint32List _blockWords(Uint8List b) {
    final d = ByteData.sublistView(b);
    for (var i = 0; i < 16; i++) {
      _words[i] = d.getUint32(i * 4, Endian.little);
    }
    return Uint32List.fromList(_words);
  }

  int get _startFlag => _blocksCompressed == 0 ? _chunkStart : 0;
  int get _chunkBytes => _blocksCompressed * _blockLen + _bufLen;

  void add(List<int> input) {
    var i = 0;
    while (i < input.length) {
      if (_chunkBytes == _chunkLen) {
        // The chunk is full and more input follows: finish it into the tree.
        final cv = _chunkOutput().chaining();
        var total = _chunkCounter + 1;
        var n = cv;
        while (total & 1 == 0) {
          n = _parentOutput(_stack.removeLast(), n).chaining();
          total >>= 1;
        }
        _stack.add(n);
        _chunkCounter++;
        _cv = Uint32List.fromList(_key);
        _blocksCompressed = 0;
        _bufLen = 0;
      }
      if (_bufLen == _blockLen) {
        final w = _compress(
          _cv,
          _blockWords(_buf),
          _chunkCounter,
          _blockLen,
          _startFlag,
        );
        _cv = Uint32List.fromList(Uint32List.sublistView(w, 0, 8));
        _blocksCompressed++;
        _bufLen = 0;
      }
      final take = (_blockLen - _bufLen) < (input.length - i)
          ? _blockLen - _bufLen
          : input.length - i;
      for (var k = 0; k < take; k++) {
        _buf[_bufLen + k] = input[i + k];
      }
      _bufLen += take;
      i += take;
    }
  }

  _Output _chunkOutput() {
    final block = Uint8List(_blockLen)..setRange(0, _bufLen, _buf);
    return _Output(
      Uint32List.fromList(_cv),
      _blockWords(block),
      _chunkCounter,
      _bufLen,
      _startFlag | _chunkEnd,
    );
  }

  _Output _parentOutput(Uint32List left, Uint32List right) {
    final block = Uint32List(16)
      ..setAll(0, left)
      ..setAll(8, right);
    return _Output(Uint32List.fromList(_key), block, 0, _blockLen, _parent);
  }

  /// The 32-byte digest as lowercase hex.
  String hexDigest() {
    var out = _chunkOutput();
    for (var i = _stack.length - 1; i >= 0; i--) {
      out = _parentOutput(_stack[i], out.chaining());
    }
    final sb = StringBuffer();
    for (final b in out.root()) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }
}

String blake3Hex(List<int> bytes) => (Blake3()..add(bytes)).hexDigest();

/// Full-file BLAKE3, reading only (1.x `scanner::hash_file`). Returns null when
/// [cancelled] says stop.
String? blake3File(String path, {bool Function()? cancelled}) {
  final f = File(path).openSync();
  try {
    final h = Blake3();
    while (true) {
      if (cancelled?.call() ?? false) return null;
      final b = f.readSync(1 << 20);
      if (b.isEmpty) break;
      h.add(b);
    }
    return h.hexDigest();
  } finally {
    f.closeSync();
  }
}
