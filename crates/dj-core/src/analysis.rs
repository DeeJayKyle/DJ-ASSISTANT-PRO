//! Local audio analysis. Everything here produces *estimates*: they are shown
//! as such, can be overridden by the DJ, and are stored with the method name
//! and version so they can be regenerated. Files are only opened for reading.
use rustfft::{num_complex::Complex32, FftPlanner};
use serde::Serialize;
use std::fs::File;
use std::path::Path;
use symphonia::core::audio::SampleBuffer;
use symphonia::core::codecs::DecoderOptions;
use symphonia::core::errors::Error as SymError;
use symphonia::core::formats::FormatOptions;
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;
use symphonia::core::probe::Hint;

pub const METHOD: &str = "dj-assistant-dsp";
pub const VERSION: i64 = 1;
/// Longest stretch of audio decoded for analysis (keeps very long mixes fast).
pub const MAX_SECONDS: f64 = 15.0 * 60.0;

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct CuePoint {
    pub ms: i64,
    pub label: String,
}

#[derive(Debug, Clone, Serialize, Default)]
pub struct Analysis {
    pub duration_ms: i64,
    pub bpm: Option<f64>,
    pub bpm_confidence: f64,
    /// Half- or double-time alternative when the tempo is ambiguous.
    pub bpm_alt: Option<f64>,
    pub key: Option<String>,
    pub camelot: Option<String>,
    pub key_confidence: f64,
    pub energy: Option<i64>,
    pub loudness_lufs: Option<f64>,
    pub peak_dbfs: Option<f64>,
    pub clipped_runs: i64,
    pub silence_start_ms: i64,
    pub silence_end_ms: i64,
    pub intro_end_ms: Option<i64>,
    pub outro_start_ms: Option<i64>,
    pub cues: Vec<CuePoint>,
    pub waveform: Vec<u8>,
    pub tempo_stable: Option<bool>,
    pub warnings: Vec<String>,
    /// Chromaprint fingerprint (raw sub-fingerprints) of the first two minutes.
    #[serde(skip)]
    pub fingerprint: Vec<u32>,
    /// AcoustID-compatible encoded fingerprint.
    #[serde(skip)]
    pub fingerprint_encoded: Option<String>,
}

pub struct Decoded {
    pub mono: Vec<f32>,
    pub sample_rate: u32,
    pub loudness_lufs: Option<f64>,
    pub peak: f32,
    pub clipped_runs: i64,
    pub fingerprint: Vec<u32>,
    pub fingerprint_encoded: Option<String>,
}

fn b64url(bytes: &[u8]) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut out = String::with_capacity(bytes.len() * 4 / 3 + 2);
    for c in bytes.chunks(3) {
        let n = (c[0] as u32) << 16
            | (*c.get(1).unwrap_or(&0) as u32) << 8
            | *c.get(2).unwrap_or(&0) as u32;
        out.push(T[(n >> 18 & 63) as usize] as char);
        out.push(T[(n >> 12 & 63) as usize] as char);
        if c.len() > 1 {
            out.push(T[(n >> 6 & 63) as usize] as char);
        }
        if c.len() > 2 {
            out.push(T[(n & 63) as usize] as char);
        }
    }
    out
}

/// Decode a file (read-only) to mono f32, measuring loudness, peak, clipping
/// and a Chromaprint fingerprint on the way.
pub fn decode(path: &Path, max_seconds: f64) -> Result<Decoded, String> {
    let file = File::open(path).map_err(|e| format!("cannot open: {e}"))?;
    let mss = MediaSourceStream::new(Box::new(file), Default::default());
    let mut hint = Hint::new();
    if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
        hint.with_extension(ext);
    }
    let probed = symphonia::default::get_probe()
        .format(
            &hint,
            mss,
            &FormatOptions::default(),
            &MetadataOptions::default(),
        )
        .map_err(|e| format!("unsupported or damaged audio: {e}"))?;
    let mut format = probed.format;
    let track = format
        .tracks()
        .iter()
        .find(|t| t.codec_params.codec != symphonia::core::codecs::CODEC_TYPE_NULL)
        .ok_or("no audio track")?
        .clone();
    let mut decoder = symphonia::default::get_codecs()
        .make(&track.codec_params, &DecoderOptions::default())
        .map_err(|e| format!("no decoder for this codec: {e}"))?;
    let sr = track
        .codec_params
        .sample_rate
        .ok_or("unknown sample rate")?;
    let mut channels = track.codec_params.channels.map(|c| c.count()).unwrap_or(0);
    let max_frames = (max_seconds * sr as f64) as usize;

    let mut mono: Vec<f32> = Vec::new();
    let mut peak = 0f32;
    let mut clipped_runs = 0i64;
    let mut run = 0usize;
    let mut meter: Option<ebur128::EbuR128> = None;
    let fp_config = rusty_chromaprint::Configuration::preset_test2();
    let mut printer = rusty_chromaprint::Fingerprinter::new(&fp_config);
    let mut fp_started = false;
    let fp_limit = 120 * sr as usize;
    let mut sample_buf: Option<SampleBuffer<f32>> = None;
    let mut i16buf: Vec<i16> = Vec::new();

    loop {
        if mono.len() >= max_frames {
            break;
        }
        let packet = match format.next_packet() {
            Ok(p) => p,
            Err(SymError::IoError(e)) if e.kind() == std::io::ErrorKind::UnexpectedEof => break,
            Err(SymError::ResetRequired) => break,
            Err(e) => {
                if mono.is_empty() {
                    return Err(format!("could not read audio: {e}"));
                }
                break;
            }
        };
        if packet.track_id() != track.id {
            continue;
        }
        let decoded = match decoder.decode(&packet) {
            Ok(d) => d,
            Err(SymError::DecodeError(_)) => continue, // skip a damaged frame
            Err(e) => {
                if mono.is_empty() {
                    return Err(format!("could not decode audio: {e}"));
                }
                break;
            }
        };
        let spec = *decoded.spec();
        if channels == 0 {
            channels = spec.channels.count();
        }
        let ch = spec.channels.count().max(1);
        if sample_buf
            .as_ref()
            .map(|b| b.capacity() < decoded.capacity() * ch)
            .unwrap_or(true)
        {
            sample_buf = Some(SampleBuffer::<f32>::new(decoded.capacity() as u64, spec));
        }
        let buf = sample_buf.as_mut().unwrap();
        buf.copy_interleaved_ref(decoded);
        let samples = buf.samples();
        if meter.is_none() {
            meter =
                ebur128::EbuR128::new(ch as u32, sr, ebur128::Mode::I | ebur128::Mode::SAMPLE_PEAK)
                    .ok();
        }
        if let Some(m) = meter.as_mut() {
            let _ = m.add_frames_f32(samples);
        }
        if !fp_started {
            fp_started = printer.start(sr, ch as u32).is_ok();
        }
        if fp_started && mono.len() < fp_limit {
            i16buf.clear();
            i16buf.extend(
                samples
                    .iter()
                    .map(|s| (s.clamp(-1.0, 1.0) * 32767.0) as i16),
            );
            printer.consume(&i16buf);
        }
        for frame in samples.chunks(ch) {
            let mut sum = 0f32;
            for &s in frame {
                let a = s.abs();
                if a > peak {
                    peak = a;
                }
                if a >= 0.999 {
                    run += 1;
                    if run == 3 {
                        clipped_runs += 1;
                    }
                } else {
                    run = 0;
                }
                sum += s;
            }
            mono.push(sum / ch as f32);
        }
    }
    if mono.is_empty() {
        return Err("no audio samples decoded".into());
    }
    let loudness = meter
        .and_then(|m| m.loudness_global().ok())
        .filter(|l| l.is_finite());
    let (fingerprint, encoded) = if fp_started {
        printer.finish();
        let fp = printer.fingerprint().to_vec();
        let enc = if fp.is_empty() {
            None
        } else {
            Some(b64url(
                &rusty_chromaprint::FingerprintCompressor::from(&fp_config).compress(&fp),
            ))
        };
        (fp, enc)
    } else {
        (vec![], None)
    };
    Ok(Decoded {
        mono,
        sample_rate: sr,
        loudness_lufs: loudness,
        peak,
        clipped_runs,
        fingerprint,
        fingerprint_encoded: encoded,
    })
}

/// Average-decimate to roughly 11 kHz for tempo and key work.
fn downsample(x: &[f32], sr: u32) -> (Vec<f32>, f32) {
    let d = ((sr as f32 / 11025.0).round() as usize).max(1);
    let out: Vec<f32> = x
        .chunks(d)
        .map(|c| c.iter().sum::<f32>() / c.len() as f32)
        .collect();
    (out, sr as f32 / d as f32)
}

fn hann(n: usize) -> Vec<f32> {
    (0..n)
        .map(|i| 0.5 - 0.5 * (2.0 * std::f32::consts::PI * i as f32 / n as f32).cos())
        .collect()
}

/// Magnitude spectrogram (frames of `n` with hop `hop`).
fn spectrogram(x: &[f32], n: usize, hop: usize) -> Vec<Vec<f32>> {
    if x.len() < n {
        return vec![];
    }
    let mut planner = FftPlanner::<f32>::new();
    let fft = planner.plan_fft_forward(n);
    let w = hann(n);
    let mut out = Vec::with_capacity((x.len() - n) / hop + 1);
    let mut buf = vec![Complex32::new(0.0, 0.0); n];
    let mut i = 0;
    while i + n <= x.len() {
        for k in 0..n {
            buf[k] = Complex32::new(x[i + k] * w[k], 0.0);
        }
        fft.process(&mut buf);
        out.push(buf[..n / 2].iter().map(|c| c.norm()).collect());
        i += hop;
    }
    out
}

fn onset_envelope(x: &[f32], sr: f32) -> (Vec<f32>, f32) {
    let hop = 128;
    let spec = spectrogram(x, 1024, hop);
    let mut env = Vec::with_capacity(spec.len());
    let mut prev: Option<Vec<f32>> = None;
    for frame in spec {
        let lf: Vec<f32> = frame.iter().map(|m| (1.0 + 10.0 * m).ln()).collect();
        let flux = match &prev {
            Some(p) => lf.iter().zip(p).map(|(a, b)| (a - b).max(0.0)).sum(),
            None => 0.0,
        };
        env.push(flux);
        prev = Some(lf);
    }
    // remove slow trend
    let w = 16usize;
    let mut out = vec![0f32; env.len()];
    let mut acc = 0f32;
    for i in 0..env.len() {
        acc += env[i];
        if i >= w {
            acc -= env[i - w];
        }
        let mean = acc / (i.min(w - 1) + 1) as f32;
        out[i] = (env[i] - mean).max(0.0);
    }
    (out, sr / hop as f32)
}

/// Estimate tempo from an onset envelope. Returns (bpm, confidence 0..1).
fn tempo_from_env(env: &[f32], fr: f32) -> Option<(f64, f64)> {
    if env.len() < (fr * 8.0) as usize {
        return None;
    }
    let ac = |lag: usize| -> f64 {
        let mut s = 0f64;
        for i in 0..env.len() - lag {
            s += (env[i] * env[i + lag]) as f64;
        }
        s / (env.len() - lag) as f64
    };
    let min_lag = (60.0 * fr / 200.0).floor() as usize;
    let max_lag = (60.0 * fr / 60.0).ceil() as usize;
    if max_lag + 2 >= env.len() {
        return None;
    }
    let vals: Vec<f64> = (0..=max_lag + 1)
        .map(|l| {
            if l < min_lag.saturating_sub(1) {
                0.0
            } else {
                ac(l)
            }
        })
        .collect();
    let mut best = None::<(usize, f64)>;
    let mut scores = Vec::new();
    for lag in min_lag..=max_lag {
        let bpm = 60.0 * fr as f64 / lag as f64;
        // emphasise periodicity that is reinforced at double the lag
        let reinforce = if 2 * lag <= max_lag + 1 {
            0.5 * vals[(2 * lag).min(vals.len() - 1)]
        } else {
            0.0
        };
        let prior = (-0.5 * ((bpm / 120.0).log2() / 1.0).powi(2)).exp();
        let s = (vals[lag] + reinforce) * prior;
        scores.push(s);
        if best.map(|b| s > b.1).unwrap_or(true) {
            best = Some((lag, s));
        }
    }
    let (lag, s) = best?;
    let mean = scores.iter().sum::<f64>() / scores.len() as f64;
    let var = scores.iter().map(|v| (v - mean).powi(2)).sum::<f64>() / scores.len() as f64;
    let conf = if var > 0.0 {
        ((s - mean) / var.sqrt() / 6.0).clamp(0.0, 1.0)
    } else {
        0.0
    };
    // parabolic refinement around the peak
    let (y0, y1, y2) = (vals[lag - 1], vals[lag], vals[lag + 1]);
    let denom = y0 - 2.0 * y1 + y2;
    let off = if denom.abs() > 1e-12 {
        (0.5 * (y0 - y2) / denom).clamp(-0.5, 0.5)
    } else {
        0.0
    };
    let bpm = 60.0 * fr as f64 / (lag as f64 + off);
    Some(((bpm * 10.0).round() / 10.0, conf))
}

const NOTES: [&str; 12] = [
    "C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B",
];
const CAMELOT_MAJOR: [&str; 12] = [
    "8B", "3B", "10B", "5B", "12B", "7B", "2B", "9B", "4B", "11B", "6B", "1B",
];
const CAMELOT_MINOR: [&str; 12] = [
    "5A", "12A", "7A", "2A", "9A", "4A", "11A", "6A", "1A", "8A", "3A", "10A",
];

pub fn camelot_for(key: &str) -> Option<&'static str> {
    let k = key.trim();
    let (root, minor) = if let Some(r) = k.strip_suffix(" minor") {
        (r, true)
    } else if let Some(r) = k.strip_suffix(" major") {
        (r, false)
    } else if let Some(r) = k.strip_suffix('m') {
        (r, true)
    } else {
        (k, false)
    };
    let alias = |r: &str| -> Option<usize> {
        let r = match r {
            "Db" => "C#",
            "D#" => "Eb",
            "Gb" => "F#",
            "G#" => "Ab",
            "A#" => "Bb",
            x => x,
        };
        NOTES.iter().position(|n| *n == r)
    };
    let i = alias(root)?;
    Some(if minor {
        CAMELOT_MINOR[i]
    } else {
        CAMELOT_MAJOR[i]
    })
}

/// Parse a Camelot code like "8A" into (number, is_minor).
pub fn parse_camelot(s: &str) -> Option<(u8, bool)> {
    let u = s.trim().to_ascii_uppercase();
    if u.len() < 2 {
        return None;
    }
    let (n, l) = u.split_at(u.len() - 1);
    let n: u8 = n.parse().ok()?;
    if !(1..=12).contains(&n) {
        return None;
    }
    match l {
        "A" => Some((n, true)),
        "B" => Some((n, false)),
        _ => None,
    }
}

/// Harmonic compatibility on the Camelot wheel: same key, ±1 step, or
/// relative major/minor. Returns a short reason, or None if not compatible.
pub fn camelot_compatible(a: &str, b: &str) -> Option<&'static str> {
    let ca = parse_camelot(a).or_else(|| camelot_for(a).and_then(parse_camelot))?;
    let cb = parse_camelot(b).or_else(|| camelot_for(b).and_then(parse_camelot))?;
    if ca == cb {
        return Some("same key");
    }
    if ca.0 == cb.0 {
        return Some("relative major/minor");
    }
    if ca.1 == cb.1 {
        let d = (ca.0 as i32 - cb.0 as i32).rem_euclid(12);
        if d == 1 || d == 11 {
            return Some("adjacent on the Camelot wheel");
        }
    }
    None
}

fn estimate_key(x: &[f32], sr: f32) -> Option<(String, String, f64)> {
    let n = 4096;
    let spec = spectrogram(x, n, n / 2);
    if spec.is_empty() {
        return None;
    }
    let mut chroma = [0f64; 12];
    for frame in &spec {
        for (k, m) in frame.iter().enumerate().skip(1) {
            let f = k as f32 * sr / n as f32;
            if !(55.0..=1760.0).contains(&f) {
                continue;
            }
            let midi = 12.0 * (f / 440.0).log2() + 69.0;
            let pc = (midi.round() as i32).rem_euclid(12) as usize;
            chroma[pc] += (*m as f64).sqrt();
        }
    }
    let major = [
        6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88,
    ];
    let minor = [
        6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17,
    ];
    let corr = |profile: &[f64; 12], root: usize| -> f64 {
        let p: Vec<f64> = (0..12).map(|i| profile[(i + 12 - root) % 12]).collect();
        let (mc, mp) = (
            chroma.iter().sum::<f64>() / 12.0,
            p.iter().sum::<f64>() / 12.0,
        );
        let mut num = 0.0;
        let (mut dc, mut dp) = (0.0, 0.0);
        for i in 0..12 {
            num += (chroma[i] - mc) * (p[i] - mp);
            dc += (chroma[i] - mc).powi(2);
            dp += (p[i] - mp).powi(2);
        }
        if dc == 0.0 || dp == 0.0 {
            0.0
        } else {
            num / (dc * dp).sqrt()
        }
    };
    let mut scores: Vec<(f64, usize, bool)> = Vec::new();
    for r in 0..12 {
        scores.push((corr(&major, r), r, false));
        scores.push((corr(&minor, r), r, true));
    }
    scores.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap_or(std::cmp::Ordering::Equal));
    let (best, root, is_minor) = scores[0];
    if best <= 0.2 {
        return None;
    }
    let conf = ((best - scores[1].0) * 5.0 + (best - 0.5).max(0.0)).clamp(0.0, 1.0);
    let name = format!(
        "{} {}",
        NOTES[root],
        if is_minor { "minor" } else { "major" }
    );
    let cam = if is_minor {
        CAMELOT_MINOR[root]
    } else {
        CAMELOT_MAJOR[root]
    };
    Some((name, cam.to_string(), conf))
}

fn db(x: f32) -> f32 {
    20.0 * x.max(1e-9).log10()
}

/// Run every analysis stage on decoded audio.
pub fn analyse_decoded(d: &Decoded) -> Analysis {
    let sr = d.sample_rate as f32;
    let x = &d.mono;
    let duration_ms = (x.len() as f64 / sr as f64 * 1000.0) as i64;
    let mut a = Analysis {
        duration_ms,
        loudness_lufs: d.loudness_lufs,
        clipped_runs: d.clipped_runs,
        ..Default::default()
    };
    a.peak_dbfs = Some(((db(d.peak) * 10.0).round() / 10.0) as f64);
    a.fingerprint = d.fingerprint.clone();
    a.fingerprint_encoded = d.fingerprint_encoded.clone();

    // Silence at start and end: 10 ms windows under -48 dBFS RMS.
    let win = (sr / 100.0) as usize;
    let rms: Vec<f32> = x
        .chunks(win.max(1))
        .map(|c| (c.iter().map(|s| s * s).sum::<f32>() / c.len() as f32).sqrt())
        .collect();
    let loud = |r: &f32| db(*r) > -48.0;
    let first = rms.iter().position(loud);
    let last = rms.iter().rposition(loud);
    match (first, last) {
        (Some(f), Some(l)) => {
            a.silence_start_ms = f as i64 * 10;
            a.silence_end_ms = (rms.len() - 1 - l) as i64 * 10;
        }
        _ => {
            a.warnings.push("The file appears to be silent.".into());
            return a;
        }
    }

    // Waveform overview: 800 peak buckets.
    let buckets = 800usize;
    let per = (x.len() / buckets).max(1);
    a.waveform = x
        .chunks(per)
        .take(buckets)
        .map(|c| (c.iter().fold(0f32, |m, s| m.max(s.abs())).min(1.0) * 255.0) as u8)
        .collect();

    // Section envelope: 0.5 s RMS in dB.
    let half = (sr / 2.0) as usize;
    let env: Vec<f32> = x
        .chunks(half.max(1))
        .map(|c| db((c.iter().map(|s| s * s).sum::<f32>() / c.len() as f32).sqrt()))
        .collect();
    if env.len() >= 16 {
        let mut sorted = env.clone();
        sorted.sort_by(|a, b| a.partial_cmp(b).unwrap());
        let p75 = sorted[sorted.len() * 3 / 4];
        let thr = p75 - 3.0;
        let run = 4;
        let intro =
            (0..env.len().saturating_sub(run)).find(|&i| env[i..i + run].iter().all(|v| *v >= thr));
        let outro = (run..env.len())
            .rev()
            .find(|&i| env[i - run..i].iter().all(|v| *v >= thr));
        if let Some(i) = intro {
            let ms = i as i64 * 500;
            if ms > a.silence_start_ms + 2000 {
                a.intro_end_ms = Some(ms);
            }
        }
        if let Some(i) = outro {
            let ms = i as i64 * 500;
            if ms < duration_ms - a.silence_end_ms - 2000 {
                a.outro_start_ms = Some(ms);
            }
        }
        // Drop: biggest rise between consecutive 4 s blocks in the middle of the track.
        let block = 8;
        let blocks: Vec<f32> = env
            .chunks(block)
            .map(|c| c.iter().sum::<f32>() / c.len() as f32)
            .collect();
        let n = blocks.len();
        let mut drop: Option<(usize, f32)> = None;
        for i in (n * 15 / 100).max(1)..(n * 75 / 100).max(1) {
            let rise = blocks[i] - blocks[i - 1];
            if rise > 4.0 && drop.map(|d| rise > d.1).unwrap_or(true) {
                drop = Some((i, rise));
            }
        }
        a.cues.push(CuePoint {
            ms: a.silence_start_ms,
            label: "First sound".into(),
        });
        if let Some(ms) = a.intro_end_ms {
            a.cues.push(CuePoint {
                ms,
                label: "Mix in (intro ends)".into(),
            });
        }
        if let Some((i, _)) = drop {
            a.cues.push(CuePoint {
                ms: (i * block) as i64 * 500,
                label: "Drop (estimate)".into(),
            });
        }
        if let Some(ms) = a.outro_start_ms {
            a.cues.push(CuePoint {
                ms,
                label: "Mix out (outro starts)".into(),
            });
        }
    }

    // Tempo and key on a ~11 kHz mono copy.
    let (low, lsr) = downsample(x, d.sample_rate);
    let (oenv, fr) = onset_envelope(&low, lsr);
    if let Some((bpm, conf)) = tempo_from_env(&oenv, fr) {
        a.bpm = Some(bpm);
        a.bpm_confidence = (conf * 100.0).round() / 100.0;
        if bpm < 95.0 && bpm * 2.0 <= 200.0 {
            a.bpm_alt = Some(bpm * 2.0);
        } else if bpm > 145.0 {
            a.bpm_alt = Some((bpm / 2.0 * 10.0).round() / 10.0);
        }
        // tempo stability: compare halves
        if oenv.len() > (fr * 40.0) as usize {
            let mid = oenv.len() / 2;
            if let (Some((b1, c1)), Some((b2, c2))) = (
                tempo_from_env(&oenv[..mid], fr),
                tempo_from_env(&oenv[mid..], fr),
            ) {
                if c1 > 0.25 && c2 > 0.25 {
                    let ratio = b1 / b2;
                    let same = [0.5, 1.0, 2.0]
                        .iter()
                        .any(|r| (ratio / r - 1.0).abs() < 0.015);
                    a.tempo_stable = Some(same);
                    if !same {
                        a.warnings.push(format!(
                            "Tempo may change during the track (about {b1:.0} BPM in the first half, {b2:.0} in the second). A fixed beatgrid may drift."
                        ));
                    }
                }
            }
        }
        if conf < 0.2 {
            a.warnings.push("Tempo is uncertain for this track.".into());
        }
    }
    if let Some((k, cam, conf)) = estimate_key(&low, lsr) {
        a.key = Some(k);
        a.camelot = Some(cam);
        a.key_confidence = (conf * 100.0).round() / 100.0;
    }

    // Energy estimate 1-10 from loudness, rhythmic activity and brightness.
    let lufs = d.loudness_lufs.unwrap_or_else(|| {
        let r = (x.iter().map(|s| (s * s) as f64).sum::<f64>() / x.len() as f64).sqrt();
        20.0 * r.max(1e-9).log10() - 0.7
    });
    let norm = |v: f64, lo: f64, hi: f64| ((v - lo) / (hi - lo)).clamp(0.0, 1.0);
    let onset_mean = if oenv.is_empty() {
        0.0
    } else {
        oenv.iter().map(|v| *v as f64).sum::<f64>() / oenv.len() as f64
    };
    let spec = spectrogram(&low[..low.len().min((lsr * 60.0) as usize)], 2048, 2048);
    let centroid = if spec.is_empty() {
        0.0
    } else {
        let mut num = 0f64;
        let mut den = 0f64;
        for frame in &spec {
            for (k, m) in frame.iter().enumerate() {
                num += k as f64 * lsr as f64 / 2048.0 * *m as f64;
                den += *m as f64;
            }
        }
        if den > 0.0 {
            num / den
        } else {
            0.0
        }
    };
    let raw = 0.55 * norm(lufs, -24.0, -6.0)
        + 0.3 * norm(onset_mean, 0.0, 6.0)
        + 0.15 * norm(centroid, 600.0, 2600.0);
    a.energy = Some((1.0 + (raw * 9.0).round()).clamp(1.0, 10.0) as i64);
    if d.clipped_runs > 10 {
        a.warnings.push(format!(
            "{} clipped passages detected (samples at full scale).",
            d.clipped_runs
        ));
    }
    if let Some(l) = d.loudness_lufs {
        if l < -20.0 {
            a.warnings.push(format!(
                "Quiet master ({l:.1} LUFS); you may need extra gain."
            ));
        }
    }
    a
}

pub fn analyse_file(path: &Path) -> Result<Analysis, String> {
    let d = decode(path, MAX_SECONDS)?;
    Ok(analyse_decoded(&d))
}

/// Fraction (0..1) of the shorter fingerprint covered by matching segments.
pub fn fingerprint_similarity(a: &[u32], b: &[u32]) -> f64 {
    if a.len() < 20 || b.len() < 20 {
        return 0.0;
    }
    let cfg = rusty_chromaprint::Configuration::preset_test2();
    match rusty_chromaprint::match_fingerprints(a, b, &cfg) {
        Ok(segs) => {
            let matched: f32 = segs
                .iter()
                .filter(|s| s.score < 10.0)
                .map(|s| s.duration(&cfg))
                .sum();
            let shorter = a.len().min(b.len()) as f32 * cfg.item_duration_in_seconds();
            if shorter <= 0.0 {
                0.0
            } else {
                (matched / shorter).min(1.0) as f64
            }
        }
        Err(_) => 0.0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn camelot_mapping_and_compatibility() {
        assert_eq!(camelot_for("A minor"), Some("8A"));
        assert_eq!(camelot_for("C major"), Some("8B"));
        assert_eq!(camelot_for("F#m"), Some("11A"));
        assert_eq!(camelot_for("Db"), Some("3B"));
        assert_eq!(camelot_compatible("8A", "8A"), Some("same key"));
        assert_eq!(
            camelot_compatible("8A", "9A"),
            Some("adjacent on the Camelot wheel")
        );
        assert_eq!(
            camelot_compatible("12A", "1A"),
            Some("adjacent on the Camelot wheel")
        );
        assert_eq!(camelot_compatible("8A", "8B"), Some("relative major/minor"));
        assert_eq!(camelot_compatible("8A", "3B"), None);
        assert_eq!(
            camelot_compatible("A minor", "E minor"),
            Some("adjacent on the Camelot wheel")
        );
    }

    fn decoded(mono: Vec<f32>, sr: u32) -> Decoded {
        let peak = mono.iter().fold(0f32, |m, s| m.max(s.abs()));
        Decoded {
            mono,
            sample_rate: sr,
            loudness_lufs: None,
            peak,
            clipped_runs: 0,
            fingerprint: vec![],
            fingerprint_encoded: None,
        }
    }

    fn clicks(bpm: f64, secs: f64, sr: u32) -> Vec<f32> {
        let n = (secs * sr as f64) as usize;
        let period = 60.0 / bpm * sr as f64;
        let mut x = vec![0f32; n];
        let mut t = 0f64;
        while (t as usize) < n {
            let s = t as usize;
            for k in 0..(sr as usize / 50).min(n - s) {
                let env = (-(k as f32) / (sr as f32 / 400.0)).exp();
                x[s + k] += 0.8 * env * ((k as f32 * 0.37).sin() + (k as f32 * 1.13).sin()) * 0.5;
            }
            t += period;
        }
        x
    }

    #[test]
    fn detects_tempo_of_click_tracks() {
        for bpm in [100.0, 124.0, 128.0, 140.0] {
            let a = analyse_decoded(&decoded(clicks(bpm, 40.0, 22050), 22050));
            let got = a.bpm.unwrap();
            let ok = (got - bpm).abs() <= 1.5
                || a.bpm_alt.map(|b| (b - bpm).abs() <= 1.5).unwrap_or(false);
            assert!(ok, "expected {bpm}, got {got} (alt {:?})", a.bpm_alt);
        }
    }

    #[test]
    fn detects_key_of_a_minor_chord() {
        let sr = 22050;
        let notes = [220.0, 261.63, 329.63, 440.0, 523.25];
        let x: Vec<f32> = (0..sr * 20)
            .map(|i| {
                notes
                    .iter()
                    .map(|f| (2.0 * std::f32::consts::PI * f * i as f32 / sr as f32).sin())
                    .sum::<f32>()
                    * 0.15
            })
            .collect();
        let a = analyse_decoded(&decoded(x, sr as u32));
        assert_eq!(a.key.as_deref(), Some("A minor"), "{:?}", a.key);
        assert_eq!(a.camelot.as_deref(), Some("8A"));
    }

    #[test]
    fn finds_silence_and_sections() {
        let sr = 22050u32;
        let mut x = vec![0f32; sr as usize * 3];
        x.extend(
            (0..sr * 30).map(|i| (i as f32 * 0.05).sin() * if i < sr * 10 { 0.1 } else { 0.7 }),
        );
        x.extend(vec![0f32; sr as usize * 2]);
        let a = analyse_decoded(&decoded(x, sr));
        assert!(
            (a.silence_start_ms - 3000).abs() <= 20,
            "{}",
            a.silence_start_ms
        );
        assert!(
            (a.silence_end_ms - 2000).abs() <= 20,
            "{}",
            a.silence_end_ms
        );
        let intro = a.intro_end_ms.expect("intro end");
        assert!((intro - 13000).abs() <= 1000, "intro {intro}");
        assert!(a.cues.iter().any(|c| c.label.starts_with("Drop")));
        assert_eq!(a.waveform.len(), 800);
    }

    #[test]
    fn silent_audio_is_reported() {
        let a = analyse_decoded(&decoded(vec![0.0; 22050 * 5], 22050));
        assert!(a.warnings[0].contains("silent"));
        assert!(a.bpm.is_none());
    }

    #[test]
    fn base64url_matches_reference() {
        assert_eq!(b64url(b"Man"), "TWFu");
        assert_eq!(b64url(b"Ma"), "TWE");
        assert_eq!(b64url(&[0xfb, 0xff]), "-_8");
    }
}
