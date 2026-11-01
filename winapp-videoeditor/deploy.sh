#!/usr/bin/env bash
# Copies .cache/ffmpeg-build/out/<arch> to the Windows build VM (C:\work\winapp-videoeditor\ffmpeg\<arch>), then
# checks the real `ffmpeg -decoders/-encoders` output there with check.sh --real.
# Usage: tools/ffmpeg/deploy.sh [--smoke] [x64] [arm64]   (no arch = both; --smoke also encodes test files on the VM)
# WIN_HOST overrides the ssh host (default: win; the VM starts on demand).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$HERE/../../.cache/ffmpeg-build/out
host=${WIN_HOST:-win}
smoke=0; arches=()
for a in "$@"; do [[ $a == --smoke ]] && smoke=1 || arches+=("$a"); done
[[ ${#arches[@]} -gt 0 ]] || arches=(arm64 x64)
W='C:\work\winapp-videoeditor'
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0

ssh $host "if not exist $W\\ffmpeg mkdir $W\\ffmpeg"
for arch in "${arches[@]}"; do
  [[ -f $OUT/$arch/ffmpeg.exe ]] || { echo "no build in $OUT/$arch"; exit 1; }
  echo "== deploy $arch"
  ssh $host "if exist $W\\ffmpeg\\$arch rmdir /s /q $W\\ffmpeg\\$arch"
  scp -q -r "$OUT/$arch" "$host:C:/work/winapp-videoeditor/ffmpeg/$arch"
  ff="$W\\ffmpeg\\$arch\\ffmpeg.exe"; fp="$W\\ffmpeg\\$arch\\ffprobe.exe"
  ssh $host "$ff -hide_banner -version" | head -1
  ssh $host "$ff -hide_banner -decoders" > "$tmp/dec-$arch.txt"
  ssh $host "$ff -hide_banner -encoders" > "$tmp/enc-$arch.txt"
  "$HERE/check.sh" --real "$tmp/dec-$arch.txt" "$tmp/enc-$arch.txt" || fail=1

  if [[ $smoke == 1 ]]; then
    echo "== smoke test $arch"
    t="$W\\t"
    run() { # run <label> <ffmpeg args> <output file>
      if ssh $host "$ff -hide_banner -loglevel error -y $2 $3" && \
         info=$(ssh $host "$fp -v error -show_entries stream=codec_name,width,height,sample_rate:format=duration -of compact $3" | tr -d '\r' | tr '\n' ' '); then
        echo "  ok   $1: $info"
      else echo "  FAIL $1"; fail=1; fi
      ssh $host "if exist $3 del /q $3" || true
    }
    run "AV1 (libsvtav1)"  "-f lavfi -i testsrc2=size=640x360:rate=30 -t 2 -c:v libsvtav1" "$t.mkv"
    run "VP9 (libvpx-vp9)" "-f lavfi -i testsrc2=size=640x360:rate=30 -t 2 -c:v libvpx-vp9 -b:v 1M" "$t.webm"
    run "Opus (libopus)"   "-f lavfi -i sine=frequency=440:duration=2 -c:a libopus" "$t.opus"
    run "MP3 (libmp3lame)" "-f lavfi -i sine=frequency=440:duration=2 -c:a libmp3lame" "$t.mp3"
    run "GIF"              "-f lavfi -i testsrc2=size=320x180:rate=10 -t 2 -c:v gif" "$t.gif"
    run "WebP (libwebp)"   "-f lavfi -i testsrc2=size=320x180:rate=10 -frames:v 1 -c:v libwebp" "$t.webp"
    run "MPEG-2 + MP2"     "-f lavfi -i testsrc2=size=640x360:rate=25 -f lavfi -i sine -t 2 -c:v mpeg2video -c:a mp2" "$t.mpg"
  fi
done
[[ $fail == 0 ]] && echo "DEPLOY + CHECK PASSED" || { echo "DEPLOY CHECK FAILED"; exit 1; }
