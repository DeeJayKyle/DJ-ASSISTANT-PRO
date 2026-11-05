import 'dart:math' as math;
import 'dart:typed_data';

/// RBJ cookbook biquads, the same shapes WebAudio's BiquadFilterNode used for
/// the 1.x decks (low shelf, peaking, high shelf, low-pass, high-pass).
/// Parameters glide towards their targets so moving a knob never clicks.
class Biquad {
  Biquad(this.type, this.freq, {this.q = 0.7071, this.gainDb = 0});
  String type; // lowshelf | peaking | highshelf | lowpass | highpass
  double freq, q, gainDb;
  double _b0 = 1, _b1 = 0, _b2 = 0, _a1 = 0, _a2 = 0;
  final _z1 = Float64List(2), _z2 = Float64List(2);
  String _key = '';

  void _design(int sr) {
    final key =
        '$type|${freq.toStringAsFixed(1)}|$q|${gainDb.toStringAsFixed(2)}|$sr';
    if (key == _key) return;
    _key = key;
    final f = freq.clamp(10, sr / 2 - 10);
    final w = 2 * math.pi * f / sr;
    final cw = math.cos(w), sw = math.sin(w);
    final a = math.pow(10, gainDb / 40).toDouble();
    double b0, b1, b2, a0, a1, a2;
    switch (type) {
      case 'lowshelf' || 'highshelf':
        // shelf slope S = 1
        final alpha = sw / 2 * math.sqrt2;
        final sa = 2 * math.sqrt(a) * alpha;
        if (type == 'lowshelf') {
          b0 = a * ((a + 1) - (a - 1) * cw + sa);
          b1 = 2 * a * ((a - 1) - (a + 1) * cw);
          b2 = a * ((a + 1) - (a - 1) * cw - sa);
          a0 = (a + 1) + (a - 1) * cw + sa;
          a1 = -2 * ((a - 1) + (a + 1) * cw);
          a2 = (a + 1) + (a - 1) * cw - sa;
        } else {
          b0 = a * ((a + 1) + (a - 1) * cw + sa);
          b1 = -2 * a * ((a - 1) + (a + 1) * cw);
          b2 = a * ((a + 1) + (a - 1) * cw - sa);
          a0 = (a + 1) - (a - 1) * cw + sa;
          a1 = 2 * ((a - 1) - (a + 1) * cw);
          a2 = (a + 1) - (a - 1) * cw - sa;
        }
      case 'peaking':
        final alpha = sw / (2 * q);
        b0 = 1 + alpha * a;
        b1 = -2 * cw;
        b2 = 1 - alpha * a;
        a0 = 1 + alpha / a;
        a1 = -2 * cw;
        a2 = 1 - alpha / a;
      case 'highpass':
        final alpha = sw / (2 * q);
        b0 = (1 + cw) / 2;
        b1 = -(1 + cw);
        b2 = (1 + cw) / 2;
        a0 = 1 + alpha;
        a1 = -2 * cw;
        a2 = 1 - alpha;
      default: // lowpass
        final alpha = sw / (2 * q);
        b0 = (1 - cw) / 2;
        b1 = 1 - cw;
        b2 = (1 - cw) / 2;
        a0 = 1 + alpha;
        a1 = -2 * cw;
        a2 = 1 - alpha;
    }
    _b0 = b0 / a0;
    _b1 = b1 / a0;
    _b2 = b2 / a0;
    _a1 = a1 / a0;
    _a2 = a2 / a0;
  }

  /// Filters stereo [l]/[r] in place (transposed direct form II).
  void process(Float32List l, Float32List r, int n, int sr) {
    _design(sr);
    final chans = [l, r];
    for (var c = 0; c < 2; c++) {
      final x = chans[c];
      var z1 = _z1[c], z2 = _z2[c];
      for (var i = 0; i < n; i++) {
        final v = x[i];
        final y = _b0 * v + z1;
        z1 = _b1 * v - _a1 * y + z2;
        z2 = _b2 * v - _a2 * y;
        x[i] = y;
      }
      // denormals and blow-ups never stick
      _z1[c] = z1.isFinite ? z1 : 0;
      _z2[c] = z2.isFinite ? z2 : 0;
    }
  }

  void reset() {
    _z1.fillRange(0, 2, 0);
    _z2.fillRange(0, 2, 0);
  }
}

/// A deck's channel strip: 3-band EQ (dB) then a filter sweep
/// (−1 low-pass … 0 off … +1 high-pass), as in 1.x.
class DeckStrip {
  final low = Biquad('lowshelf', 220);
  final mid = Biquad('peaking', 1000, q: 0.8);
  final high = Biquad('highshelf', 3800);
  final filt = Biquad('lowpass', 22000, q: 0.9);
  double eqLow = 0, eqMid = 0, eqHigh = 0, filter = 0;

  void process(Float32List l, Float32List r, int n, int sr) {
    if (eqLow != 0) {
      low.gainDb = eqLow;
      low.process(l, r, n, sr);
    }
    if (eqMid != 0) {
      mid.gainDb = eqMid;
      mid.process(l, r, n, sr);
    }
    if (eqHigh != 0) {
      high.gainDb = eqHigh;
      high.process(l, r, n, sr);
    }
    if (filter.abs() >= 0.02) {
      if (filter < 0) {
        filt.type = 'lowpass';
        filt.freq = 20000 * math.pow(2, filter * 10).toDouble();
      } else {
        filt.type = 'highpass';
        filt.freq = 20 * math.pow(2, filter * 10).toDouble();
      }
      filt.process(l, r, n, sr);
    } else {
      filt.reset();
    }
  }
}
