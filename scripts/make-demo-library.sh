#!/usr/bin/env bash
# Generates a realistic-length DEMO library (synthetic beats + chords with
# invented artist names) for screenshots and manual testing. Not committed.
# Usage: scripts/make-demo-library.sh <output-dir>
set -euo pipefail
OUT="${1:?output dir}"
mkdir -p "$OUT"
ff() { ffmpeg -nostdin -hide_banner -loglevel error -y "$@"; }
# name|artist|title|genre|year|bpm|root_hz|minor(0/1)|energy(0-1)|bitrate|ext
while IFS='|' read -r folder artist title genre year bpm root minor energy br ext; do
  [[ -z "$folder" ]] && continue
  mkdir -p "$OUT/$folder"
  third=$(python3 -c "print($root*(1.1892 if $minor else 1.2599))")
  fifth=$(python3 -c "print($root*1.4983)")
  beat=$(python3 -c "print(60/$bpm)")
  expr="$energy*0.9*sin(2*PI*55*t)*exp(-28*mod(t,$beat)) + $energy*0.25*sin(2*PI*$root*t) + 0.18*sin(2*PI*$third*t) + 0.15*sin(2*PI*$fifth*t) + $energy*0.12*(random(0)-0.5)*exp(-60*mod(t+$beat/2,$beat))"
  expr="${expr//,/\\,}"
  file="$OUT/$folder/$artist - $title.$ext"
  codec=(-c:a libmp3lame -b:a "${br}k"); [[ "$ext" == "flac" ]] && codec=(-c:a flac)
  ff -f lavfi -i "aevalsrc=$expr:s=22050:d=200" -af "afade=t=in:d=12,afade=t=out:st=185:d=15" -ac 1 "${codec[@]}" \
     -metadata artist="$artist" -metadata title="$title" -metadata genre="$genre" -metadata date="$year" "$file"
done <<'LIST'
Afrobeats|Kito Lagoon|Sunset on the Mainland|Afrobeats|2019|104|220|1|0.75|320|mp3
Afrobeats|Kito Lagoon|Danfo Ride|Afrobeats|2021|108|246.9|1|0.85|320|mp3
Afrobeats|Ama Velvet|Golden Hour|Afrobeats|2016|102|196|0|0.6|256|mp3
Afrobeats|Ama Velvet|Golden Hour (Clean)|Afrobeats|2016|102|196|0|0.6|256|mp3
Afrobeats|Nile Ferry|Kampala Nights|Afrobeats|2014|100|185|1|0.55|128|mp3
Afrobeats|Nile Ferry|Boda Rush|Afrobeats|2018|110|233|1|0.9|96|mp3
Amapiano|Log Drum Society|Piano Lights|Amapiano|2022|112|174.6|1|0.7|320|mp3
Amapiano|Log Drum Society|Midnight Shaker|Amapiano|2023|113|164.8|1|0.8|320|mp3
House|Deep Tenant|Warehouse Memory|House|1996|124|220|1|0.8|320|mp3
House|Deep Tenant|Basement Hours|House|1997|125|233|1|0.9|128|mp3
House|Velvet Arcade|Mirrorball Fever|Disco|1979|118|261.6|0|0.7|192|mp3
House|Velvet Arcade|Roller Rink|Disco|1981|120|293.7|0|0.75|192|mp3
House|Quiet Harbour|Low Tide|Deep House|2021|120|130.8|1|0.45|0|flac
House|Quiet Harbour|Shoreline|Deep House|2020|122|146.8|1|0.5|0|flac
Hip Hop|Concrete Poets|Rooftop Cipher|Hip Hop|2004|92|196|1|0.7|320|mp3
Hip Hop|Concrete Poets|Block Party (Radio Edit)|Hip Hop|2006|95|220|1|0.8|320|mp3
RnB|Silk District|Late Calls|R&B|2002|88|174.6|0|0.45|256|mp3
RnB|Silk District|Slow Burn|R&B|2001|72|164.8|0|0.35|256|mp3
Throwbacks|Brass Avenue|Wedding Bells Funk|Funk|1978|112|196|0|0.85|320|mp3
Throwbacks|Brass Avenue|Last Dance|Soul|1983|100|174.6|0|0.6|320|mp3
LIST
echo "Demo library written to $OUT"
