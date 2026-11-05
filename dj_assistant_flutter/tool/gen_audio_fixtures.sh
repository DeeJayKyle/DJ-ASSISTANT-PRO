#!/usr/bin/env bash
# Builds the decoder test clips in test/fixtures/audio and their expected output
# (test/golden/pcm.json) with ffmpeg: frame count, rate, channels and the sha256
# of the 32-bit float little-endian samples ffmpeg decodes. Run from the
# dj_assistant_flutter folder. Needs ffmpeg.
set -euo pipefail
out=test/fixtures/audio
rm -rf "$out"; mkdir -p "$out"
ff() { ffmpeg -nostdin -hide_banner -loglevel error -y "$@"; }
# Music-like stereo source: two tones, a sweep and a little noise, 0.6 s.
src="aevalsrc=0.4*sin(2*PI*220*t)+0.2*sin(2*PI*(440+300*t)*t)+0.05*(random(0)-0.5)|0.3*sin(2*PI*330*t)+0.05*(random(1)-0.5):s=44100:d=0.4"
noise="anoisesrc=d=0.3:c=white:a=0.9:r=44100:seed=7"
ff -f lavfi -i "$src" -c:a flac -sample_fmt s16 -compression_level 8 "$out/lpc_stereo16.flac"
ff -f lavfi -i "$src" -c:a flac -sample_fmt s16 -compression_level 0 "$out/fixed_stereo16.flac"
ff -f lavfi -i "$src" -c:a flac -sample_fmt s16 -ch_mode mid_side -compression_level 5 "$out/midside16.flac"
ff -f lavfi -i "$src" -c:a flac -ch_mode left_side "$out/leftside24.flac"
ff -f lavfi -i "$src" -c:a flac -ch_mode right_side "$out/rightside24.flac"
ff -f lavfi -i "$src" -ac 1 -c:a flac -sample_fmt s32 -bits_per_raw_sample 24 -compression_level 12 "$out/mono24.flac"
ff -f lavfi -i "$noise" -c:a flac -compression_level 0 "$out/noise_verbatim.flac"
ff -f lavfi -i "anullsrc=r=48000:cl=stereo" -t 0.3 -c:a flac "$out/silence48k.flac"
ff -f lavfi -i "$src" -c:a flac -frame_size 1152 -lpc_type cholesky -lpc_passes 2 "$out/cholesky24.flac"
ff -f lavfi -i "$src" -c:a pcm_u8 "$out/u8.wav"
ff -f lavfi -i "$src" -c:a pcm_s16le "$out/s16.wav"
ff -f lavfi -i "$src" -c:a pcm_s24le "$out/s24.wav"
ff -f lavfi -i "$src" -c:a pcm_s32le "$out/s32.wav"
ff -f lavfi -i "$src" -c:a pcm_f32le "$out/f32.wav"
ff -f lavfi -i "$src" -ac 6 -c:a pcm_s16le "$out/surround51.wav"
ff -f lavfi -i "$src" -c:a pcm_s16be "$out/s16.aiff"
ff -f lavfi -i "$src" -c:a pcm_s24be "$out/s24.aiff"
ff -f lavfi -i "$src" -c:a pcm_s8 -f aiff "$out/s8.aiff"
lib=../crates/dj-core/tests/fixtures/library
golden=test/golden/pcm.json
{
  echo "{"
  first=1
  for f in "$out"/* "$lib/Lossless/Low Tide.flac" "$lib/Lossless/Driftwood.aiff" "$lib/Lossless/untagged recording.wav"; do
    rel=${f#../crates/dj-core/tests/fixtures/}
    rel=${rel#test/fixtures/}
    info=$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate,channels -of csv=p=0 "$f")
    rate=${info%,*}; ch=${info#*,}
    tmp=$(mktemp)
    ffmpeg -nostdin -loglevel error -y -i "$f" -f f32le -c:a pcm_f32le "$tmp"
    bytes=$(stat -c %s "$tmp")
    sha=$(sha256sum "$tmp" | cut -d' ' -f1)
    rm -f "$tmp"
    [ $first = 1 ] || echo ","
    first=0
    printf '  "%s": {"sample_rate": %s, "channels": %s, "frames": %s, "sha256": "%s"}' \
      "$rel" "$rate" "$ch" $((bytes / 4 / ch)) "$sha"
  done
  echo
  echo "}"
} > "$golden"
echo "wrote $golden"

# Lossy reference for the Media Foundation test (Windows): ffmpeg's frame count and
# RMS per file. Decoders differ by a few samples of delay, so the test allows a margin.
python3 - "$lib" > test/golden/lossy.json <<'PY'
import json, os, struct, subprocess, sys, math
lib = sys.argv[1]
out = {}
for rel in ["House/Old School/Basement Hours.mp3", "Afrobeats/Lagos Lights - Sunrise Groove.mp3",
            "House/Neon Steps.m4a", "Lossless/Shoreline.m4a"]:
    path = os.path.join(lib, rel)
    info = subprocess.check_output(["ffprobe", "-v", "error", "-select_streams", "a:0", "-show_entries",
        "stream=sample_rate,channels", "-of", "csv=p=0", path], text=True).strip().split(",")
    raw = subprocess.check_output(["ffmpeg", "-nostdin", "-loglevel", "error", "-i", path, "-f", "f32le", "-"])
    n = len(raw) // 4
    xs = struct.unpack("<%df" % n, raw)
    out["library/" + rel] = {"sample_rate": int(info[0]), "channels": int(info[1]),
        "frames": n // int(info[1]), "rms": math.sqrt(sum(x * x for x in xs) / max(1, n))}
print(json.dumps(out, indent=2))
PY
echo "wrote test/golden/lossy.json"

# Music-like clips for analysis parity (tempo, key, sections, loudness): a kick on
# every beat, a hat on the off-beat and a chord pad, with silence, a quiet intro
# and a drop. 1.x analyses the same files (crates/dj-core/tests/golden_meta.rs).
an=test/fixtures/analysis
rm -rf "$an"; mkdir -p "$an"
kick() { echo "0.9*exp(-mod(t,60/$1)*28)*sin(2*PI*52*mod(t,60/$1)*(1+2*exp(-mod(t,60/$1)*40)))"; }
hat() { echo "0.15*exp(-mod(t+30/$1,60/$1)*90)*(random(3)-0.5)"; }
amin="0.06*(sin(2*PI*220*t)+sin(2*PI*261.63*t)+sin(2*PI*329.63*t)+sin(2*PI*440*t))"
cmaj="0.06*(sin(2*PI*261.63*t)+sin(2*PI*329.63*t)+sin(2*PI*392*t)+sin(2*PI*523.25*t))"
fsmin="0.06*(sin(2*PI*185*t)+sin(2*PI*220*t)+sin(2*PI*277.18*t)+sin(2*PI*369.99*t))"
ff -f lavfi -i "aevalsrc='if(lt(t,3),0,if(lt(t,13),0.18,1)*($(kick 124)+$(hat 124)+$amin))':s=22050:d=40" \
  -c:a flac -sample_fmt s16 "$an/afro124_amin.flac"
ff -f lavfi -i "aevalsrc='($(kick 128)+$(hat 128)+$cmaj)|($(kick 128)+$cmaj)':s=44100:d=30" \
  -c:a flac -sample_fmt s16 "$an/house128_cmaj_stereo.flac"
ff -f lavfi -i "aevalsrc='0.7*($(kick 90)+$(hat 90)+$fsmin)':s=22050:d=30" -c:a flac -sample_fmt s16 "$an/slow90_fsmin.flac"
ff -f lavfi -i "aevalsrc='$(kick 174)+$(hat 174)+$amin':s=22050:d=30" -c:a flac -sample_fmt s16 "$an/dnb174.flac"
ff -f lavfi -i "aevalsrc='min(1,max(-1,1.6*($(kick 126)+$amin)))':s=22050:d=20" -c:a flac -sample_fmt s16 "$an/clipped126.flac"
ff -f lavfi -i "anullsrc=r=22050:cl=mono" -t 6 -c:a pcm_s16le "$an/silent.wav"
echo "wrote $an"

# Tag-writing fixtures: an M4A with the movie header before the audio (so a
# larger tag must move the audio and its chunk offsets).
tg=test/fixtures/tags
rm -rf "$tg"; mkdir -p "$tg"
ff -i "$lib/House/Neon Steps.m4a" -c copy -movflags +faststart "$tg/faststart.m4a"
echo "wrote $tg"
