#!/usr/bin/env bash
# Regenerates the synthetic audio fixtures used by automated tests.
# Every file is a generated sine tone (no copyrighted audio). Tags use
# invented artist/title names chosen to exercise matching edge cases.
set -euo pipefail
OUT="${1:-crates/dj-core/tests/fixtures/library}"
rm -rf "$OUT"; mkdir -p "$OUT/Afrobeats" "$OUT/House/Old School" "$OUT/Café Ünïcode" "$OUT/Copies" "$OUT/Broken" "$OUT/Lossless"
tone() { # dur freq
  echo "-f lavfi -i sine=frequency=$2:duration=$1:sample_rate=44100 -ac 1"
}
ff() { ffmpeg -nostdin -hide_banner -loglevel error -y "$@"; }
meta() { # artist title genre year
  echo "-metadata artist=$1 -metadata title=$2 -metadata genre=$3 -metadata date=$4"
}
# High-bitrate MP3 with BPM/key tags
ff $(tone 2 440) -c:a libmp3lame -b:a 320k -metadata artist="Lagos Lights" -metadata title="Sunrise Groove (feat. Ada)" -metadata album="Coastline" \
   -metadata genre="Afrobeats" -metadata date="2016" -metadata TBPM="104" -metadata TKEY="8A" -id3v2_version 3 "$OUT/Afrobeats/Lagos Lights - Sunrise Groove.mp3"
# Exact copy (byte-identical) in another folder
cp "$OUT/Afrobeats/Lagos Lights - Sunrise Groove.mp3" "$OUT/Copies/Sunrise Groove (copy).mp3"
# Same song, different encode (possible duplicate, not exact)
ff $(tone 2 440) -c:a libmp3lame -b:a 192k -metadata artist="Lagos Lights" -metadata title="Sunrise Groove" \
   -metadata genre="Afrobeats" -metadata date="2016" "$OUT/Copies/Sunrise Groove 192.mp3"
# Alternate versions: remix and live
ff $(tone 3 523) -c:a libmp3lame -b:a 256k -metadata artist="Lagos Lights" -metadata title="Sunrise Groove (Kofi Remix)" \
   -metadata genre="Afrobeats" -metadata date="2018" "$OUT/Afrobeats/Sunrise Groove (Kofi Remix).mp3"
ff $(tone 2 494) -c:a libmp3lame -b:a 256k -metadata artist="Lagos Lights" -metadata title="Sunrise Groove (Live)" \
   -metadata genre="Afrobeats" -metadata date="2019" "$OUT/Afrobeats/Sunrise Groove (Live).mp3"
# Clean version of another song
ff $(tone 2 587) -c:a libmp3lame -b:a 256k -metadata artist="Harbour Kings" -metadata title="Night Market (Clean)" \
   -metadata genre="Afrobeats" -metadata date="2014" "$OUT/Afrobeats/Night Market (Clean).mp3"
# Low-bitrate lossy MP3 (CBR 96 kbps)
ff $(tone 2 330) -c:a libmp3lame -b:a 96k -metadata artist="Deep Tenant" -metadata title="Warehouse 94" \
   -metadata genre="House" -metadata date="1994" -metadata TBPM="124" "$OUT/House/Old School/Deep Tenant - Warehouse 94.mp3"
# Exactly at threshold (128) - must NOT be flagged (< threshold only)
ff $(tone 2 349) -c:a libmp3lame -b:a 128k -metadata artist="Deep Tenant" -metadata title="Basement Hours" \
   -metadata genre="House" -metadata date="1997" "$OUT/House/Old School/Basement Hours.mp3"
# Low-bitrate AAC in M4A
ff $(tone 2 392) -c:a aac -b:a 64k -metadata artist="Velvet Arcade" -metadata title="Neon Steps" \
   -metadata genre="Disco" -metadata date="1979" "$OUT/House/Neon Steps.m4a"
# Lossless: FLAC, WAV, AIFF, ALAC (some will have a low *numeric* bitrate for a sine tone)
ff $(tone 2 262) -c:a flac -metadata artist="Quiet Harbour" -metadata title="Low Tide" -metadata genre="Ambient" -metadata date="2021" "$OUT/Lossless/Low Tide.flac"
ff $(tone 1 262) -c:a pcm_s16le "$OUT/Lossless/untagged recording.wav"
ff $(tone 1 294) -c:a pcm_s16be -write_id3v2 1 -metadata artist="Quiet Harbour" -metadata title="Driftwood" "$OUT/Lossless/Driftwood.aiff"
ff $(tone 1 330) -c:a alac -metadata artist="Quiet Harbour" -metadata title="Shoreline" -metadata genre="Ambient" "$OUT/Lossless/Shoreline.m4a"
# Ogg Vorbis and Opus
ff $(tone 1 440) -c:a libvorbis -q:a 4 -metadata ARTIST="Velvet Arcade" -metadata TITLE="Mirrorball" -metadata GENRE="Disco" -metadata DATE="1981" "$OUT/House/Mirrorball.ogg"
ff $(tone 1 440) -c:a libopus -b:a 96k -metadata ARTIST="Velvet Arcade" -metadata TITLE="Roller Rink" "$OUT/House/Roller Rink.opus"
# Unicode + spaces in folder and file names, accented tags
ff $(tone 1 659) -c:a libmp3lame -b:a 192k -metadata artist="Beyoncé Tribute Band" -metadata title="Déjà Vu Medley" \
   -metadata genre="R&B" -metadata date="2006" "$OUT/Café Ünïcode/Beyoncé – Déjà Vu (Medley).mp3"
# Same title, same artist but very different duration => not a duplicate candidate
ff $(tone 5 700) -c:a libmp3lame -b:a 192k -metadata artist="Harbour Kings" -metadata title="Intro" -metadata genre="Afrobeats" "$OUT/Afrobeats/Intro (album A).mp3"
ff $(tone 1 700) -c:a libmp3lame -b:a 192k -metadata artist="Harbour Kings" -metadata title="Intro" -metadata genre="Afrobeats" "$OUT/Afrobeats/Intro (album B).mp3"
# Corrupt / unsupported / non-audio
head -c 4096 /dev/urandom > "$OUT/Broken/corrupt.mp3"
printf 'fLaC' > "$OUT/Broken/truncated.flac"
head -c 2048 /dev/urandom > "$OUT/Broken/old format.wma"
echo "not music" > "$OUT/Broken/notes.txt"
: > "$OUT/Broken/empty.mp3"
echo "Fixtures written to $OUT"; find "$OUT" -type f | sort

# ---- Video fixtures (separate folder so audio tests keep their counts) ----
VOUT="${2:-crates/dj-core/tests/fixtures/video}"
rm -rf "$VOUT"; mkdir -p "$VOUT/Clips"
vsrc="-f lavfi -i testsrc2=size=320x180:rate=25:duration=2 -f lavfi -i sine=frequency=440:duration=2:sample_rate=44100"
ff $vsrc -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a aac -b:a 96k -shortest -metadata artist="Lagos Lights" -metadata title="Sunrise Groove (Official Video)" -metadata genre="Afrobeats" -metadata date="2016" "$VOUT/Clips/Lagos Lights - Sunrise Groove (Video).mp4"
ff $vsrc -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a aac -b:a 96k -shortest -metadata artist="Velvet Arcade" -metadata title="Mirrorball (Video)" "$VOUT/Clips/Mirrorball.mov"
ff $vsrc -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a aac -b:a 96k -shortest "$VOUT/Clips/untitled clip.m4v"
ff $vsrc -c:v libvpx-vp9 -b:v 200k -c:a libopus -b:a 64k -shortest -metadata ARTIST="Deep Tenant" -metadata TITLE="Warehouse Visuals" -metadata GENRE="House" "$VOUT/Clips/Deep Tenant - Warehouse Visuals.mkv"
ff $vsrc -c:v libvpx -b:v 200k -c:a libvorbis -shortest "$VOUT/Clips/Loop.webm"
ff $vsrc -c:v mpeg4 -q:v 8 -c:a libmp3lame -b:a 128k -shortest "$VOUT/Clips/Old Visual.avi"
ff -f lavfi -i sine=frequency=440:duration=2 -c:a aac -b:a 128k -metadata artist="Quiet Harbour" -metadata title="Audio In MP4" "$VOUT/Clips/Audio only.mp4"
head -c 4096 /dev/urandom > "$VOUT/Clips/legacy.wmv"
head -c 4096 /dev/urandom > "$VOUT/Clips/broken.mp4"
echo "Video fixtures written to $VOUT"; ls -la "$VOUT/Clips"
