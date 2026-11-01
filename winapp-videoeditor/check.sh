#!/usr/bin/env bash
# Legal check for the LGPL-only FFmpeg build.
#   tools/ffmpeg/check.sh <arch>                       check the configured tree: .cache/ffmpeg-build/codec_list-<arch>.c,
#                                                      configure-out-<arch>.txt and tools/ffmpeg/configure-<arch>.txt
#   tools/ffmpeg/check.sh --real <decoders.txt> <encoders.txt>
#                                                      check the real output of `ffmpeg -hide_banner -decoders/-encoders`
# Fails (exit 1) if a forbidden codec is present, a required one is missing, or the build is GPL/nonfree.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
C=$HERE/../../.cache/ffmpeg-build

# Forbidden (whole names, as decoder or encoder): patent-encumbered codecs and the external libs that implement them.
FORBID='^(h261|h263.*|h264.*|hevc.*|vvc.*|aac.*|ac3.*|eac3.*|ac4.*|vc1.*|wmv.*|mpeg4.*|msmpeg4.*|flv|rv10|rv20|mss2|dca|truehd|mlp|prores.*|dnxhd|cfhd|avs.*|cavs|wma.*|xma[12]|amr.*|dolby_e|lcevc.*|lib(openh264|x26[245].*|kvazaar|vvenc|lcevc.*|uavs3d|davs2|xavs.*|fdk_aac|opencore_amr.*|vo_amrwbenc|xevd|xeve|xvid))$'
# Allowed exceptions (encoders only): wrappers around Windows Media Foundation / GPU driver encoders.
ALLOW_ENC='^(h264_mf|hevc_mf|aac_mf|h264_nvenc|hevc_nvenc|h264_amf|hevc_amf|h264_qsv|hevc_qsv)$'
NEED_ENC="h264_mf hevc_mf aac_mf av1_mf h264_nvenc hevc_nvenc av1_nvenc h264_amf hevc_amf av1_amf libsvtav1 libvpx_vp8 libvpx_vp9 libopus libmp3lame libwebp gif png mjpeg flac mpeg2video mpeg1video mp2 alac apng pcm_s16le subrip ass mov_text webvtt"
NEED_DEC="libdav1d vp8 vp9 av1 opus vorbis theora mp3 mp2 flac alac pcm_s16le gif png apng mjpeg webp mpeg1video mpeg2video subrip ass mov_text webvtt"

fail=0
# check_list <kind> <file with one name per line> <required names>
check_list() {
  local kind=$1 file=$2 need=$3 bad n
  bad=$(grep -E "$FORBID" "$file" || true)
  [[ $kind == encoder ]] && bad=$(echo "$bad" | grep -vE "$ALLOW_ENC" || true)
  bad=$(echo $bad)
  if [[ -n $bad ]]; then echo "  FAIL forbidden ${kind}s present: $bad"; fail=1; else echo "  ok   no forbidden ${kind}s ($(wc -l < "$file" | tr -d ' ') ${kind}s)"; fi
  local miss=""
  for n in $need; do grep -qx "$n" "$file" || miss="$miss $n"; done
  if [[ -n $miss ]]; then echo "  FAIL required ${kind}s missing:$miss"; fail=1; else echo "  ok   all required ${kind}s present"; fi
}

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

if [[ ${1:-} == --real ]]; then
  # ffmpeg prints codec names (e.g. libvpx, libvpx-vp9); map to the codec_list.c spelling.
  for k in decoder:$2 encoder:$3; do
    kind=${k%%:*}; f=${k#*:}
    tr -d '\r' < "$f" | awk 'p && NF>=2 {print $2} /^ *-+ *$/ {p=1}' | sed 's/-/_/g; s/^libvpx$/libvpx_vp8/; s/^msmpeg4$/msmpeg4v3/' | sort -u > "$tmp/$kind"
    echo "== real ffmpeg ${kind}s ($f)"
    check_list $kind "$tmp/$kind" "$([[ $kind == decoder ]] && echo "$NEED_DEC" || echo "$NEED_ENC")"
  done
else
  arch=${1:?usage: check.sh <x64|arm64> | --real decoders.txt encoders.txt}
  list=$C/codec_list-$arch.c; out=$C/configure-out-$arch.txt; line=$HERE/configure-$arch.txt
  echo "== $arch: $list"
  for kind in decoder encoder; do
    sed -n "s/.*&ff_\([a-z0-9_]*\)_$kind,.*/\1/p" "$list" | sed 's/^movtext$/mov_text/' | sort -u > "$tmp/$kind"
    check_list $kind "$tmp/$kind" "$([[ $kind == decoder ]] && echo "$NEED_DEC" || echo "$NEED_ENC")"
  done
  echo "== $arch: configure output $out"
  for kind in decoder encoder; do
    # "Enabled decoders:" block = names in columns until the next blank line
    awk -v h="Enabled ${kind}s:" '$0==h {p=1; next} p && /^$/ {exit} p {for (i=1;i<=NF;i++) print $i}' "$out" | sed 's/^movtext$/mov_text/' | sort -u > "$tmp/cfg-$kind"
    [[ -s $tmp/cfg-$kind ]] || { echo "  FAIL no 'Enabled ${kind}s' block in configure output"; fail=1; continue; }
    if ! diff -q "$tmp/$kind" "$tmp/cfg-$kind" >/dev/null; then echo "  FAIL configure output and codec_list.c differ for ${kind}s"; fail=1; fi
    check_list $kind "$tmp/cfg-$kind" "$([[ $kind == decoder ]] && echo "$NEED_DEC" || echo "$NEED_ENC")"
  done
  echo "== $arch: licence"
  if grep -qE -- '--enable-(gpl|nonfree)' "$line"; then echo "  FAIL configure line has --enable-gpl/--enable-nonfree"; fail=1; else echo "  ok   no --enable-gpl / --enable-nonfree in $line"; fi
  lic=$(sed -n 's/^License: //p' "$out")
  if [[ $lic == "LGPL version 3 or later" ]]; then echo "  ok   configure says License: $lic"; else echo "  FAIL configure says License: $lic"; fail=1; fi
fi

[[ $fail == 0 ]] && echo "CHECK PASSED" || { echo "CHECK FAILED"; exit 1; }
