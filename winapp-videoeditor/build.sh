#!/usr/bin/env bash
# Builds the LGPL-only FFmpeg (shared DLLs + ffmpeg.exe + ffprobe.exe) for Windows x64 and/or ARM64 with llvm-mingw,
# on macOS (Apple Silicon). Usage: tools/ffmpeg/build.sh [x64] [arm64]   (no args = both)
# Pins: tools/ffmpeg/VERSION. Work dir: .cache/ffmpeg-build/{src,prefix-<arch>,build-<arch>,out/<arch>}.
# Needs (brew): nasm meson ninja cmake pkg-config autoconf automake libtool.
# Legal rule: no --enable-gpl / --enable-nonfree; patent-encumbered codecs are removed (see README.md).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
C=$ROOT/.cache/ffmpeg-build
SRC=$C/src
JOBS=${JOBS:-6}
export PATH=/opt/homebrew/bin:$HOME/bin:/usr/bin:/bin:/usr/sbin:/sbin
export LC_ALL=C
ARCHES=("$@"); [[ ${#ARCHES[@]} -gt 0 ]] || ARCHES=(x64 arm64)

for t in nasm meson ninja cmake pkg-config autoreconf curl shasum; do
  command -v $t >/dev/null || { echo "missing tool: $t (brew install nasm meson ninja cmake pkg-config autoconf automake libtool)"; exit 1; }
done

# ---------- sources ----------
# pin <name> <field>: field 2=version 3=file 4=url 5=sha256 (bash 3.2 compatible, no associative arrays)
pin() { awk -F'|' -v n="$1" -v f="$2" '$1==n {print $f}' "$HERE/VERSION"; }
NAMES=$(awk -F'|' '!/^#/ && NF==5 {print $1}' "$HERE/VERSION")

mkdir -p "$SRC"
for name in $NAMES; do
  f=$SRC/$(pin $name 3)
  [[ -f $f ]] || { echo "== download $name"; curl -fL --retry 3 -o "$f.part" "$(pin $name 4)" && mv "$f.part" "$f"; }
  echo "$(pin $name 5)  $f" | shasum -a 256 -c - >/dev/null || { echo "SHA-256 mismatch: $f"; exit 1; }
done
echo "== all sources verified"

TC=$C/$(pin llvm-mingw 3 | sed "s/[.]tar[.]xz$//")
[[ -x $TC/bin/clang ]] || { echo "== extract llvm-mingw"; tar xf "$SRC/$(pin llvm-mingw 3)" -C "$C"; }
export PATH=$TC/bin:$PATH

# unpack <name> <dir>: fresh copy of a source tree into <dir>
unpack() {
  rm -rf "$2"; mkdir -p "$2"
  tar xf "$SRC/$(pin "$1" 3)" -C "$2" --strip-components=1
}

build_arch() {
  local arch=$1 T FFARCH VPXT MCPU CMPROC
  case $arch in
    x64)   T=x86_64-w64-mingw32;  FFARCH=x86_64;  VPXT=x86_64-win64-gcc; MCPU=x86_64;  CMPROC=AMD64 ;;
    arm64) T=aarch64-w64-mingw32; FFARCH=aarch64; VPXT=arm64-win64-gcc;  MCPU=aarch64; CMPROC=ARM64 ;;
    *) echo "unknown arch $arch"; exit 1 ;;
  esac
  local P=$C/prefix-$arch B=$C/build-$arch O=$C/out/$arch
  mkdir -p "$P/lib/pkgconfig" "$P/include" "$B"
  export CC=$T-clang CXX=$T-clang++ AR=$T-llvm-ar RANLIB=$T-llvm-ranlib NM=$T-nm STRIP=$T-strip WINDRES=$T-windres
  export CFLAGS="-O2" CXXFLAGS="-O2" LDFLAGS=""
  export PKG_CONFIG_LIBDIR=$P/lib/pkgconfig PKG_CONFIG_PATH=""

  cat > "$B/cross.meson" <<EOF
[binaries]
c = '$T-clang'
cpp = '$T-clang++'
ar = '$T-llvm-ar'
strip = '$T-strip'
windres = '$T-windres'
nasm = 'nasm'
pkg-config = 'pkg-config'
[host_machine]
system = 'windows'
cpu_family = '$MCPU'
cpu = '$MCPU'
endian = 'little'
EOF
  cat > "$B/toolchain.cmake" <<EOF
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR $CMPROC)
set(CMAKE_C_COMPILER $TC/bin/$T-clang)
set(CMAKE_CXX_COMPILER $TC/bin/$T-clang++)
set(CMAKE_RC_COMPILER $TC/bin/$T-windres)
set(CMAKE_AR $TC/bin/$T-llvm-ar)
set(CMAKE_RANLIB $TC/bin/$T-llvm-ranlib)
set(CMAKE_ASM_NASM_COMPILER /opt/homebrew/bin/nasm)
set(CMAKE_FIND_ROOT_PATH $P $TC/$T)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
EOF
  local CMK=(-G Ninja -DCMAKE_TOOLCHAIN_FILE=$B/toolchain.cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$P
             -DCMAKE_INSTALL_LIBDIR=lib -DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON)
  done_() { [[ -f $P/.done-$1 ]]; }
  mark() { touch "$P/.done-$1"; rm -rf "$B/$1"; }

  # Link winpthreads statically: deps' .pc files ask for -lpthread, and $P/lib is searched before the toolchain's
  # libpthread.dll.a, so no libwinpthread-1.dll ships.
  cp "$TC/$T/lib/libwinpthread.a" "$P/lib/libpthread.a"

  # zlib (static; FFmpeg finds it as -lz)
  if ! done_ zlib; then echo "== [$arch] zlib"; unpack zlib "$B/zlib"
    make -C "$B/zlib" -f win32/Makefile.gcc -j$JOBS PREFIX=$T- CC=$CC AR=$AR RC=$WINDRES CFLAGS="-O2 -Wall" libz.a
    cp "$B/zlib/libz.a" "$P/lib/"; cp "$B/zlib/zlib.h" "$B/zlib/zconf.h" "$P/include/"
    printf 'prefix=%s\nlibdir=${prefix}/lib\nincludedir=${prefix}/include\nName: zlib\nDescription: zlib\nVersion: %s\nLibs: -L${libdir} -lz\nCflags: -I${includedir}\n' "$P" "$(pin zlib 2)" > "$P/lib/pkgconfig/zlib.pc"
    mark zlib; fi

  # dav1d (AV1 decoder, BSD-2)
  if ! done_ dav1d; then echo "== [$arch] dav1d"; unpack dav1d "$B/dav1d"
    meson setup "$B/dav1d/build" "$B/dav1d" --cross-file "$B/cross.meson" --prefix "$P" --libdir lib \
      --buildtype release --default-library static -Denable_tools=false -Denable_tests=false -Denable_examples=false
    ninja -C "$B/dav1d/build" -j$JOBS install
    mark dav1d; fi

  # SVT-AV1 (AV1 encoder, BSD-3 + AOM patent licence)
  if ! done_ svtav1; then echo "== [$arch] SVT-AV1"; unpack svt-av1 "$B/svtav1"
    cmake -S "$B/svtav1" -B "$B/svtav1/build" "${CMK[@]}" -DBUILD_APPS=OFF -DBUILD_TESTING=OFF -DSVT_AV1_LTO=OFF \
      -DENABLE_NASM=ON -DEXCLUDE_HASH=ON
    cmake --build "$B/svtav1/build" -j$JOBS; cmake --install "$B/svtav1/build"
    mark svtav1; fi

  # libvpx (VP8/VP9, BSD-3)
  if ! done_ libvpx; then echo "== [$arch] libvpx"; unpack libvpx "$B/libvpx"
    (cd "$B/libvpx" && CROSS=$T- LD=$CC AS=nasm ./configure --target=$VPXT --prefix="$P" --enable-static --disable-shared \
       --enable-pic --disable-examples --disable-tools --disable-docs --disable-unit-tests --enable-vp9-highbitdepth \
       --enable-runtime-cpu-detect && make -j$JOBS && make install)
    mark libvpx; fi

  # opus (BSD-3)
  if ! done_ opus; then echo "== [$arch] opus"; unpack opus "$B/opus"
    # Windows ARM64: opus has no NEON run-time detection for mingw, but every ARM64 Windows CPU has NEON.
    local OPUSARCH=(); [[ $arch == arm64 ]] && OPUSARCH=(-DOPUS_MAY_HAVE_NEON=OFF -DOPUS_PRESUME_NEON=ON "-DCMAKE_C_FLAGS=-O2 -DOPUS_ARM_MAY_HAVE_NEON_INTR")
    cmake -S "$B/opus" -B "$B/opus/build" "${CMK[@]}" -DOPUS_BUILD_TESTING=OFF -DOPUS_BUILD_PROGRAMS=OFF \
      -DOPUS_BUILD_SHARED_LIBRARY=OFF -DOPUS_FORTIFY_SOURCE=OFF -DOPUS_STACK_PROTECTOR=OFF -DOPUS_DRED=OFF -DOPUS_OSCE=OFF ${OPUSARCH[@]+"${OPUSARCH[@]}"}
    cmake --build "$B/opus/build" -j$JOBS; cmake --install "$B/opus/build"
    mark opus; fi

  # LAME (MP3 encoder, LGPL-2.0+)
  if ! done_ lame; then echo "== [$arch] lame"; unpack lame "$B/lame"
    cp /opt/homebrew/share/automake-*/config.sub /opt/homebrew/share/automake-*/config.guess "$B/lame/"
    # lame 3.100 lists a symbol it no longer has; harmless for static but keep the export list clean
    sed -i '' '/lame_init_old/d' "$B/lame/include/libmp3lame.sym"
    (cd "$B/lame" && ./configure --host=$T --prefix="$P" --enable-static --disable-shared --disable-frontend \
       --disable-decoder --disable-gtktest --disable-analyzer-hooks --with-pic && make -j$JOBS && make install)
    mark lame; fi

  # libwebp (BSD-3)
  if ! done_ libwebp; then echo "== [$arch] libwebp"; unpack libwebp "$B/libwebp"
    cmake -S "$B/libwebp" -B "$B/libwebp/build" "${CMK[@]}" -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF \
      -DWEBP_BUILD_DWEBP=OFF -DWEBP_BUILD_GIF2WEBP=OFF -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF \
      -DWEBP_BUILD_WEBPINFO=OFF -DWEBP_BUILD_WEBPMUX=OFF -DWEBP_BUILD_EXTRAS=OFF -DWEBP_BUILD_FUZZTEST=OFF \
      -DWEBP_BUILD_LIBWEBPMUX=ON
    cmake --build "$B/libwebp/build" -j$JOBS; cmake --install "$B/libwebp/build"
    mark libwebp; fi

  # nv-codec-headers (MIT) and AMF headers (MIT): headers only
  if ! done_ nvheaders; then echo "== [$arch] nv-codec-headers"; unpack nv-codec-headers "$B/nvheaders"
    make -C "$B/nvheaders" PREFIX="$P" install
    mark nvheaders; fi
  if ! done_ amf; then echo "== [$arch] AMF headers"; unpack amf-headers "$B/amf"
    rm -rf "$P/include/AMF"; cp -R "$B/amf/AMF" "$P/include/AMF"
    mark amf; fi

  # ---------- FFmpeg ----------
  echo "== [$arch] FFmpeg $(pin ffmpeg 2)"
  unpack ffmpeg "$B/ffmpeg"
  # Codecs out by the legal rule (decoders and encoders; globs are expanded by FFmpeg's configure).
  local BAN="h261,h263*,h264*,hevc*,aac*,ac3*,eac3*,vc1*,wmv*,mpeg4*,msmpeg4*,flv,rv10,rv20,mss2,dca,truehd,mlp,vvc*,prores*,dnxhd,cfhd,avs,cavs,wma*,xma1,xma2,amr*,dolby_e"
  local BANLIBS="libopenh264,libx264,libx264rgb,libx262,libx265,libkvazaar,libvvenc,libdavs2,libuavs3d,libxavs,libxavs2,libfdk_aac,libopencore_amrnb,libopencore_amrwb,libvo_amrwbenc,libxevd,libxeve,libxvid"
  local KEEPENC="aac_mf,h264_mf,hevc_mf,h264_nvenc,hevc_nvenc,h264_amf,hevc_amf"
  local CFG=(
    --prefix="$B/ffmpeg-install"
    --target-os=mingw32 --arch=$FFARCH --enable-cross-compile --cross-prefix=$T-
    --cc=$T-clang --cxx=$T-clang++ --ar=$T-llvm-ar --ranlib=$T-llvm-ranlib --nm=$T-nm --strip=$T-strip
    --pkg-config=pkg-config --pkg-config-flags=--static
    --enable-version3
    --enable-shared --disable-static --disable-debug --disable-doc --disable-ffplay --disable-network
    --disable-autodetect --enable-w32threads
    --enable-mediafoundation --enable-d3d11va --enable-dxva2
    --enable-ffnvcodec --enable-nvenc --enable-nvdec --disable-cuvid --enable-amf
    --enable-zlib --enable-libdav1d --enable-libsvtav1 --enable-libvpx --enable-libopus --enable-libmp3lame --enable-libwebp
    --disable-libopenh264 --disable-libx264 --disable-libx265 --disable-libkvazaar --disable-libvvenc
    --disable-liblcevc-dec --disable-libuavs3d --disable-libdavs2 --disable-libxavs2 --disable-libfdk-aac
    --disable-libopencore-amrnb --disable-libopencore-amrwb --disable-libvo-amrwbenc --disable-libxevd --disable-libxeve
    --disable-decoder="$BAN,$BANLIBS" --disable-encoder="$BAN,$BANLIBS"
    --enable-encoder="$KEEPENC"
    --disable-filter=gfxcapture
    --extra-cflags="-I$P/include" --extra-ldflags="-L$P/lib"
    --extra-version=koyk-lgpl
  )
  printf '%s\n' "./configure ${CFG[*]}" > "$HERE/configure-$arch.txt"
  (cd "$B/ffmpeg" && ./configure "${CFG[@]}" > "$B/configure-out.txt" 2>&1) || { tail -40 "$B/ffmpeg/ffbuild/config.log"; exit 1; }
  cp "$B/configure-out.txt" "$C/configure-out-$arch.txt"
  cp "$B/ffmpeg/libavcodec/codec_list.c" "$C/codec_list-$arch.c"
  "$HERE/check.sh" "$arch"   # legal check on the configured tree before spending time compiling
  make -C "$B/ffmpeg" -j$JOBS
  make -C "$B/ffmpeg" install

  # ---------- output ----------
  rm -rf "$O"; mkdir -p "$O"
  cp "$B/ffmpeg-install/bin/"{ffmpeg.exe,ffprobe.exe} "$O/"
  cp "$B/ffmpeg-install/bin/"*.dll "$O/"
  $T-strip "$O/"*.exe "$O/"*.dll
  # Fail if anything but FFmpeg's own DLLs and Windows system DLLs is imported (no libc++/libunwind/winpthread).
  local bad
  bad=$(for f in "$O/"*.exe "$O/"*.dll; do $T-objdump -p "$f" | sed -n 's/^ *DLL Name: //p'; done | sort -u |
        grep -viE '^(av|sw|postproc)[a-z]*-[0-9]+\.dll$|^api-ms-win-|^(kernel32|user32|gdi32|advapi32|ole32|oleaut32|shell32|avicap32|ws2_32|bcrypt|mfplat|mf|mfuuid|strmiids|psapi|shlwapi|secur32|ncrypt|crypt32|d3d11|dxgi|dxva2|mfreadwrite|winmm|uuid)\.dll$' || true)
  [[ -z $bad ]] || { echo "unexpected DLL imports in $arch: $(echo $bad)"; exit 1; }
  write_license "$O" "$B/ffmpeg"
  rm -rf "$B"   # build tree is not needed any more (prefix-<arch> keeps the static deps)
  echo "== [$arch] done: $(du -sh "$O" | cut -f1) in $O"
}

write_license() {
  local O=$1 F=$2
  {
    cat <<EOF
FFmpeg $(pin ffmpeg 2) for Windows, built by Koyk Studio from unmodified upstream sources.
Licence: GNU Lesser General Public License version 3 (configure --enable-version3; no --enable-gpl, no --enable-nonfree).
The FFmpeg libraries are the separate DLLs in this folder (avcodec, avformat, avutil, avfilter, avdevice, swscale,
swresample); you may replace them with your own compatible build. Build scripts and pinned sources:
tools/ffmpeg/build.sh and tools/ffmpeg/VERSION in the app's source; upstream source: $(pin ffmpeg 4)

Patent-encumbered codecs are NOT included (no decoder or encoder for H.264, HEVC, VVC, AAC, AC-3/E-AC-3, DTS,
TrueHD/MLP, VC-1/WMV, MPEG-4 Part 2/H.263/H.261, WMA, AMR, ProRes, DNxHD, CineForm, AVS, LCEVC). H.264/HEVC/AAC
encoding uses the encoders that ship with Windows (Media Foundation) or the GPU driver (NVENC, AMF).

Libraries statically linked into these DLLs:
  dav1d $(pin dav1d 2)            BSD 2-Clause           https://code.videolan.org/videolan/dav1d
  SVT-AV1 $(pin svt-av1 2)  BSD 3-Clause Clear + Alliance for Open Media Patent License 1.0  https://gitlab.com/AOMediaCodec/SVT-AV1
  libvpx $(pin libvpx 2)  BSD 3-Clause (+ WebM additional IP rights grant)  https://chromium.googlesource.com/webm/libvpx
  Opus $(pin opus 2)             BSD 3-Clause           https://opus-codec.org
  LAME $(pin lame 2)             LGPL 2.0 or later      https://lame.sourceforge.io (source: $(pin lame 4))
  libwebp $(pin libwebp 2)          BSD 3-Clause           https://chromium.googlesource.com/webm/libwebp
  zlib $(pin zlib 2)             zlib licence           https://zlib.net
  nv-codec-headers $(pin nv-codec-headers 2)  MIT (headers only; the NVIDIA driver is loaded at run time)
  AMF headers $(pin amf-headers 2)      MIT (headers only; the AMD driver is loaded at run time)
  llvm-mingw runtime (mingw-w64 CRT/winpthreads: ZPL/MIT/public domain; compiler-rt: Apache 2.0 with LLVM exception)

================================================================================
GNU LESSER GENERAL PUBLIC LICENSE, version 3 (FFmpeg COPYING.LGPLv3):
================================================================================
EOF
    cat "$F/COPYING.LGPLv3"
    printf '\n================================================================================\nGNU GENERAL PUBLIC LICENSE, version 3 (referenced by the LGPLv3; FFmpeg COPYING.GPLv3):\n================================================================================\n'
    cat "$F/COPYING.GPLv3"
  } > "$O/LICENSE.txt"
}

for a in "${ARCHES[@]}"; do build_arch "$a"; done
rm -rf "$C/scratch"
du -sh "$C/out/"* 2>/dev/null || true
