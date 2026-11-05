import 'dart:math' as math;
import 'dart:typed_data';

/// EBU R128 / ITU-R BS.1770 integrated loudness, as computed by 1.x (the
/// `ebur128` crate, mode I): K-weighting, 400 ms gating blocks every 100 ms,
/// absolute gate −70 LUFS, relative gate −10 LU.
class LoudnessMeter {
  LoudnessMeter(this.channels, int rate)
    : _s100 = (rate + 5) ~/ 10,
      _state = List.generate(channels, (_) => Float64List(5)),
      _weights = _channelWeights(channels) {
    final (b, a) = _coefficients(rate.toDouble());
    _b = b;
    _a = a;
    _ring = List.generate(channels, (_) => Float64List(4 * _s100));
    _needed = 4 * _s100;
  }

  final int channels;
  final int _s100;
  late final Float64List _b, _a;
  final List<Float64List> _state;
  final List<double> _weights;
  late final List<Float64List> _ring; // filtered samples of the last 400 ms
  var _pos = 0;
  late int _needed;
  final _blocks = <double>[];

  // 10^((−70 + 0.691) / 10): blocks below the absolute gate are dropped.
  static const _absoluteGate = 0.000000117246530458229809506033624374;

  static List<double> _channelWeights(int ch) {
    // Default channel map: L R C (LFE unused) Ls Rs; 4 ch = L R Ls Rs; 5 ch = L R C Ls Rs.
    if (ch == 4) return [1, 1, 1.41, 1.41];
    if (ch == 5) return [1, 1, 1, 1.41, 1.41];
    const map = [1.0, 1.0, 1.0, 0.0, 1.41, 1.41];
    return [for (var i = 0; i < ch; i++) i < 6 ? map[i] : 0.0];
  }

  static (Float64List, Float64List) _coefficients(double rate) {
    var f0 = 1681.974450955533;
    const g = 3.999843853973347;
    var q = 0.7071752369554196;
    var k = math.tan(math.pi * f0 / rate);
    final vh = math.pow(10.0, g / 20.0).toDouble();
    final vb = math.pow(vh, 0.4996667741545416).toDouble();
    final a0 = 1.0 + k / q + k * k;
    final pb = [
      (vh + vb * k / q + k * k) / a0,
      2.0 * (k * k - vh) / a0,
      (vh - vb * k / q + k * k) / a0,
    ];
    final pa = [1.0, 2.0 * (k * k - 1.0) / a0, (1.0 - k / q + k * k) / a0];
    const rb = [1.0, -2.0, 1.0];
    f0 = 38.13547087602444;
    q = 0.5003270373238773;
    k = math.tan(math.pi * f0 / rate);
    final ra = [
      1.0,
      2.0 * (k * k - 1.0) / (1.0 + k / q + k * k),
      (1.0 - k / q + k * k) / (1.0 + k / q + k * k),
    ];
    return (
      Float64List.fromList([
        pb[0] * rb[0],
        pb[0] * rb[1] + pb[1] * rb[0],
        pb[0] * rb[2] + pb[1] * rb[1] + pb[2] * rb[0],
        pb[1] * rb[2] + pb[2] * rb[1],
        pb[2] * rb[2],
      ]),
      Float64List.fromList([
        pa[0] * ra[0],
        pa[0] * ra[1] + pa[1] * ra[0],
        pa[0] * ra[2] + pa[1] * ra[1] + pa[2] * ra[0],
        pa[1] * ra[2] + pa[2] * ra[1],
        pa[2] * ra[2],
      ]),
    );
  }

  /// Adds interleaved frames.
  void add(Float32List frames) {
    final n = frames.length ~/ channels;
    final b = _b, a = _a;
    for (var i = 0; i < n; i++) {
      for (var c = 0; c < channels; c++) {
        if (_weights[c] == 0) continue;
        final s = _state[c];
        s[0] =
            frames[i * channels + c] -
            a[1] * s[1] -
            a[2] * s[2] -
            a[3] * s[3] -
            a[4] * s[4];
        var y =
            b[0] * s[0] + b[1] * s[1] + b[2] * s[2] + b[3] * s[3] + b[4] * s[4];
        s[4] = s[3];
        s[3] = s[2];
        s[2] = s[1];
        s[1] = s[0];
        if (y.abs() < 2.2250738585072014e-308) y = 0;
        _ring[c][_pos] = y;
      }
      _pos = (_pos + 1) % (4 * _s100);
      if (--_needed == 0) {
        _block();
        _needed = _s100;
      }
    }
  }

  void _block() {
    final len = 4 * _s100;
    var sum = 0.0;
    for (var c = 0; c < channels; c++) {
      final w = _weights[c];
      if (w == 0) continue;
      final r = _ring[c];
      var cs = 0.0;
      // Storage order, as 1.x sums its ring buffer.
      for (var i = 0; i < len; i++) {
        final v = r[i];
        cs += v * v;
      }
      sum += cs * w;
    }
    final e = sum / len;
    if (e >= _absoluteGate) _blocks.add(e);
  }

  /// Integrated loudness in LUFS, or null when nothing is above the gate.
  double? get integrated {
    if (_blocks.isEmpty) return null;
    var total = 0.0;
    for (final e in _blocks) {
      total += e;
    }
    final rel = total / _blocks.length * math.pow(10.0, -1.0);
    var n = 0;
    var gated = 0.0;
    for (final e in _blocks) {
      if (e >= rel) {
        gated += e;
        n++;
      }
    }
    if (n == 0) return null;
    final l = 10.0 * math.log(gated / n) / math.ln10 - 0.691;
    return l.isFinite ? l : null;
  }
}
