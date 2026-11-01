# FFmpeg for the video editor (LGPL-only, Windows x64 + ARM64)

Our own trimmed FFmpeg build: shared DLLs (`avcodec`, `avformat`, `avutil`, `avfilter`, `avdevice`, `swscale`,
`swresample`) plus `ffmpeg.exe` and `ffprobe.exe`, cross-compiled on the Mac with llvm-mingw. Pinned versions and
SHA-256 of every source and the toolchain: `VERSION`. Exact configure lines: `configure-x64.txt`, `configure-arm64.txt`.

## The legal rule

- **LGPL only.** Configured with `--enable-version3` (LGPLv3), never `--enable-gpl` or `--enable-nonfree`.
- **No patent-pool codecs.** Decoders *and* encoders are removed for H.264, HEVC, VVC, AAC, AC-3/E-AC-3, DTS, TrueHD/MLP,
  VC-1/WMV, MPEG-4 Part 2 (+ MS-MPEG4, H.263, H.261, FLV1, RealVideo 1/2), WMA (+ XMA), AMR, ProRes, DNxHD/HR, CineForm,
  AVS/CAVS, Dolby E, MSS2 (uses VC-1), LCEVC, and every external library for them (x264, x265, openh264, kvazaar,
  vvenc, fdk-aac, opencore-amr, ...). The app decodes those with Windows' own codecs.
- **Kept wrappers** (no codec implementation inside; they call Windows or the GPU driver): Media Foundation
  `h264_mf`, `hevc_mf`, `aac_mf`, `av1_mf`, `mp3_mf`; NVIDIA `h264_nvenc`, `hevc_nvenc`, `av1_nvenc` (+ NVDEC hwaccel for
  AV1/VP9/MPEG-2...); AMD `h264_amf`, `hevc_amf`, `av1_amf`; D3D11VA/DXVA2 hwaccels (only for the decoders that remain).
  `ac3_mf` is left out to stay strictly inside the list above. Intel QSV (libvpl) is not built. The `gfxcapture`
  filter (Windows Graphics Capture) is disabled: it is C++ and would ship libc++.
- **Kept**: all demuxers/muxers, parsers and bitstream filters (stream copy/remux of H.264/HEVC/AAC works without
  decoding), default filters, swscale, swresample, file/pipe protocols (network disabled). Codecs: AV1 (dav1d decode,
  SVT-AV1 encode, native decode), VP8/VP9 (libvpx + native decode), Opus (libopus + native), Vorbis decode, FLAC,
  MP3 (native decode, LAME encode), MP2, PCM, ALAC, GIF, PNG/APNG, MJPEG/JPEG, WebP (libwebp encode, native decode),
  MPEG-1/2 video, Theora decode, subtitles (SRT, ASS, mov_text, WebVTT), zlib.
- `check.sh` enforces this: `check.sh <arch>` on the configured tree (`codec_list.c` + configure output + configure
  line), `check.sh --real dec.txt enc.txt` on real `ffmpeg -decoders/-encoders` output. `build.sh` runs it before
  compiling, `deploy.sh` runs it on the VM.

## Rebuild

```sh
brew install nasm meson ninja cmake pkg-config autoconf automake libtool
tools/ffmpeg/build.sh            # both arches (or: x64 / arm64); -j6, about 10 min per arch on the Mac mini
tools/ffmpeg/deploy.sh --smoke   # copy out/<arch> to win:C:\work\winapp-videoeditor\ffmpeg\<arch>, check, smoke-test
```

Everything goes to `.cache/ffmpeg-build/` (gitignored): `src/` (pinned tarballs, SHA-256 checked), the llvm-mingw
toolchain, `prefix-<arch>/` (static deps), `out/<arch>/` (what ships). Per-arch build trees are deleted when done.
Static deps (dav1d, SVT-AV1, libvpx, opus, LAME, libwebp, zlib) are linked into the FFmpeg DLLs; the C runtime is the
Windows UCRT, no libc++/libunwind/winpthread DLLs ship (build.sh fails if any other DLL is imported).

## LGPL notes

- FFmpeg ships as separate, unmodified DLLs; a user may replace them with their own compatible build.
- LAME (LGPL) is linked statically into `avcodec-*.dll`, which is itself LGPL and replaceable as a whole.
- Corresponding source = these scripts + the pinned upstream tarballs listed in `VERSION` (no patches).
- Each `out/<arch>/LICENSE.txt` carries the LGPLv3 (+ GPLv3 it references) and the list of bundled libraries and licences.
