import 'dart:math' as math;
import 'dart:typed_data';

import 'dsp.dart' show fft;
import 'stretch.dart' show resample;

/// AI stem separation with HTDemucs (Meta, MIT licence) exported to ONNX — the
/// Pro Stems AI pack. The model takes a 7.8 s stereo segment as a waveform plus
/// its spectrogram and returns, for drums / bass / other / vocals, a
/// spectrogram and a waveform that are added together. Pre- and
/// post-processing match 1.x exactly: periodic Hann, FFT 4096, hop 1024, 1/√N,
/// reflect padding, frames 2…337; segments overlap by a quarter and cross-fade.
///
/// [ModelRun] is the model call (ONNX Runtime in the app), injected so the
/// signal path is testable without the model.
const aiSr = 44100;
const nFft = 4096;
const hop = 1024;
const seg = 343980;
const bins = 2048;
const frames = 336;
const overlap = 0.25;
const aiStemNames = ['drums', 'bass', 'other', 'vocals'];

/// (freq [4×4×BINS×FRAMES] or null, time [4×2×SEG]).
typedef ModelRun = (Float32List?, Float32List) Function(
  Float32List waveform,
  Float32List spec,
);

final _hannP = <int, Float64List>{};
Float64List _hannPeriodic(int n) => _hannP.putIfAbsent(n, () {
  final w = Float64List(n);
  for (var i = 0; i < n; i++) {
    w[i] = 0.5 * (1 - math.cos(2 * math.pi * i / n));
  }
  return w;
});

Float32List reflectPad(Float32List x, int left, int right) {
  final n = x.length, out = Float32List(left + n + right);
  for (var i = 0; i < left; i++) {
    out[i] = x[math.min(left - i, n - 1)];
  }
  out.setRange(left, left + n, x);
  for (var i = 0; i < right; i++) {
    out[left + n + i] = x[math.max(0, n - 2 - i)];
  }
  return out;
}

class Spectrum {
  Spectrum(this.real, this.imag, this.frames, this.bins);
  final Float32List real, imag;
  final int frames, bins;
}

/// Frame-major STFT: real/imag [frames × (N/2+1)].
Spectrum stft(Float32List x) {
  final fr = (x.length - nFft) ~/ hop + 1, nb = nFft ~/ 2 + 1;
  final w = _hannPeriodic(nFft), scale = 1 / math.sqrt(nFft);
  final real = Float32List(fr * nb), imag = Float32List(fr * nb);
  final re = Float64List(nFft), im = Float64List(nFft);
  for (var f = 0; f < fr; f++) {
    final s = f * hop;
    for (var i = 0; i < nFft; i++) {
      re[i] = x[s + i] * w[i];
      im[i] = 0;
    }
    fft(re, im);
    final o = f * nb;
    for (var k = 0; k < nb; k++) {
      real[o + k] = re[k] * scale;
      imag[o + k] = im[k] * scale;
    }
  }
  return Spectrum(real, imag, fr, nb);
}

/// Inverse of [stft] (weighted overlap-add).
Float32List istft(
  Float32List real,
  Float32List imag,
  int fr,
  int nb,
  int length,
) {
  final out = Float32List(length), wsum = Float32List(length);
  final w = _hannPeriodic(nFft), scale = math.sqrt(nFft);
  final re = Float64List(nFft), im = Float64List(nFft);
  for (var f = 0; f < fr; f++) {
    re.fillRange(0, nFft, 0);
    im.fillRange(0, nFft, 0);
    for (var k = 0; k < nb; k++) {
      re[k] = real[f * nb + k];
      im[k] = imag[f * nb + k];
    }
    for (var k = 1; k < nb - 1; k++) {
      re[nFft - k] = re[k];
      im[nFft - k] = -im[k];
    }
    // inverse FFT = conj(FFT(conj(x))) / N
    for (var i = 0; i < nFft; i++) {
      im[i] = -im[i];
    }
    fft(re, im);
    final s = f * hop;
    for (var i = 0; i < nFft && s + i < length; i++) {
      out[s + i] += re[i] / nFft * w[i] * scale;
      wsum[s + i] += w[i] * w[i];
    }
  }
  for (var i = 0; i < length; i++) {
    if (wsum[i] > 1e-8) out[i] /= wsum[i];
  }
  return out;
}

/// Model inputs for one segment: waveform [2 × SEG] and spectrogram
/// [4 × BINS × FRAMES].
(Float32List, Float32List) prepare(Float32List left, Float32List right) {
  final l = Float32List(seg), r = Float32List(seg);
  l.setRange(0, math.min(seg, left.length), left);
  r.setRange(0, math.min(seg, right.length), right);
  final le = (seg / hop).ceil(),
      pad = (hop ~/ 2) * 3,
      padR = pad + le * hop - seg,
      c = nFft ~/ 2;
  final sl = stft(reflectPad(reflectPad(l, pad, padR), c, c));
  final sr = stft(reflectPad(reflectPad(r, pad, padR), c, c));
  final spec = Float32List(4 * bins * frames);
  const plane = bins * frames;
  for (var f = 0; f < frames; f++) {
    final src = (f + 2) * sl.bins;
    for (var b = 0; b < bins; b++) {
      final o = b * frames + f;
      spec[o] = sl.real[src + b];
      spec[plane + o] = sl.imag[src + b];
      spec[2 * plane + o] = sr.real[src + b];
      spec[3 * plane + o] = sr.imag[src + b];
    }
  }
  final waveform = Float32List(2 * seg)
    ..setRange(0, seg, l)
    ..setRange(seg, 2 * seg, r);
  return (waveform, spec);
}

/// One stem's spectrogram output back to a stereo waveform of SEG samples.
List<Float32List> inverse(Float32List freq, int stem) {
  const plane = bins * frames, pb = bins + 1, pf = frames + 4;
  final base = stem * 4 * plane;
  const len = (pf - 1) * hop + nFft, off = nFft ~/ 2 + (hop ~/ 2) * 3;
  Float32List ch(int rp, int ip) {
    final real = Float32List(pf * pb), imag = Float32List(pf * pb);
    for (var f = 0; f < frames; f++) {
      for (var b = 0; b < bins; b++) {
        final s = base + b * frames + f, d = (f + 2) * pb + b;
        real[d] = freq[s + rp * plane];
        imag[d] = freq[s + ip * plane];
      }
    }
    return Float32List.fromList(
      Float32List.sublistView(istft(real, imag, pf, pb, len), off, off + seg),
    );
  }

  return [ch(0, 1), ch(2, 3)];
}

class Cancelled implements Exception {
  @override
  String toString() => 'cancelled';
}

/// Separates a stereo song (any rate) into the four AI stems at its own rate.
Map<String, List<Float32List>> separateAi(
  List<Float32List> mix,
  int sampleRate,
  ModelRun run, {
  void Function(int done, int total)? onProgress,
  bool Function()? cancelled,
}) {
  final n0 = mix[0].length;
  final n = (n0 * aiSr / sampleRate).round();
  final right = mix.length > 1 ? mix[1] : mix[0];
  final L = sampleRate == aiSr ? mix[0] : resample(mix[0], n);
  final R = sampleRate == aiSr ? right : resample(right, n);
  final stride = (seg * (1 - overlap)).floor();
  final total = math.max(1, (math.max(0, n - seg) / stride).ceil() + 1);
  final out = [
    for (final _ in aiStemNames) [Float32List(n), Float32List(n)],
  ];
  final weight = Float32List(n);
  var done = 0;
  for (var start = 0; start < n; start += stride) {
    if (cancelled?.call() ?? false) throw Cancelled();
    final len = math.min(seg, n - start);
    final (waveform, spec) = prepare(
      Float32List.sublistView(L, start, start + len),
      Float32List.sublistView(R, start, start + len),
    );
    final (freq, time) = run(waveform, spec);
    double fade(int i) => math.min(
      1,
      math.min((i + 1) / (stride * 0.5), (len - i) / (stride * 0.5)),
    );
    for (var t = 0; t < 4; t++) {
      final fx = freq == null ? null : inverse(freq, t);
      for (var c = 0; c < 2; c++) {
        final o = out[t][c], tb = (t * 2 + c) * seg;
        for (var i = 0; i < len; i++) {
          o[start + i] +=
              (time[tb + i] + (fx == null ? 0 : fx[c][i])) * fade(i);
        }
      }
    }
    for (var i = 0; i < len; i++) {
      weight[start + i] += fade(i);
    }
    onProgress?.call(++done, total);
    if (start + seg >= n) break;
  }
  for (final st in out) {
    for (final c in st) {
      for (var i = 0; i < n; i++) {
        if (weight[i] > 0) c[i] /= weight[i];
      }
    }
  }
  Float32List back(Float32List c) => sampleRate == aiSr ? c : resample(c, n0);
  return {
    for (var i = 0; i < aiStemNames.length; i++)
      aiStemNames[i]: [for (final c in out[i]) back(c)],
  };
}
