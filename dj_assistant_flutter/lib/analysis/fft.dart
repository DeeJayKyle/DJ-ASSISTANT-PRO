import 'dart:math' as math;
import 'dart:typed_data';

/// In-place iterative radix-2 complex FFT (forward). [re] and [im] have a
/// power-of-two length.
class Fft {
  Fft(this.n)
    : _cos = Float64List(n ~/ 2),
      _sin = Float64List(n ~/ 2),
      _rev = Int32List(n) {
    if (n < 2 || (n & (n - 1)) != 0) {
      throw ArgumentError('FFT size must be a power of two');
    }
    for (var i = 0; i < n ~/ 2; i++) {
      _cos[i] = math.cos(2 * math.pi * i / n);
      _sin[i] = -math.sin(2 * math.pi * i / n);
    }
    var bits = 0;
    while ((1 << bits) < n) {
      bits++;
    }
    for (var i = 0; i < n; i++) {
      var r = 0;
      for (var b = 0; b < bits; b++) {
        if ((i & (1 << b)) != 0) r |= 1 << (bits - 1 - b);
      }
      _rev[i] = r;
    }
  }

  final int n;
  final Float64List _cos, _sin;
  final Int32List _rev;

  void transform(Float64List re, Float64List im) {
    for (var i = 0; i < n; i++) {
      final j = _rev[i];
      if (j > i) {
        final tr = re[i];
        re[i] = re[j];
        re[j] = tr;
        final ti = im[i];
        im[i] = im[j];
        im[j] = ti;
      }
    }
    for (var size = 2; size <= n; size <<= 1) {
      final half = size >> 1;
      final step = n ~/ size;
      for (var start = 0; start < n; start += size) {
        for (var k = 0; k < half; k++) {
          final wr = _cos[k * step], wi = _sin[k * step];
          final a = start + k, b = a + half;
          final xr = re[b] * wr - im[b] * wi;
          final xi = re[b] * wi + im[b] * wr;
          re[b] = re[a] - xr;
          im[b] = im[a] - xi;
          re[a] += xr;
          im[a] += xi;
        }
      }
    }
  }
}
