# ffmpeg-build

The exact sources and build scripts of the LGPL-only FFmpeg builds that KoykStudio apps ship for Windows
(x64 + ARM64). This is the source offer for FFmpeg and its libraries under the GNU LGPL.

- `winapp-videoeditor/`: the build in **Video Editor: Cut, Effects & 4K** (FFmpeg 9.0.2). `VERSION` pins every
  source with its URL and SHA-256; `configure-*.txt` are the exact configure lines; `build.sh` rebuilds it.
  The unmodified source tarballs are attached to the release `videoeditor-ffmpeg-9.0.2`.

These builds are LGPL only: no `--enable-gpl`, no `--enable-nonfree`, and no H.264, HEVC, AAC or other patent-pool
codecs (the apps use Windows' own codecs for those). The FFmpeg DLLs in the apps are separate files you may replace
with your own build.

Questions: support@koykstudio.com
