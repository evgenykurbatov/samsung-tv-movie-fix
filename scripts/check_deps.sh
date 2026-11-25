#!/usr/bin/env bash
# Check that every tool the scripts need is installed, show versions and the features the recipes rely on.
#
# Usage: check_deps.sh
#
# Required: mkvtoolnix (mkvmerge, mkvinfo, mkvextract, mkvpropedit), ffmpeg + ffprobe, jq, python3 >= 3.8,
#           file, strings (binutils), numfmt/stat (coreutils), cmp (diffutils), iconv, findmnt (util-linux).
# Optional: filefrag (e2fsprogs: badsector_map.sh), journalctl (kernel disk-error checks),
#           smartctl (smartmontools: SMART data, needs sudo), lsof (who keeps a drive busy), shellcheck (linting).
# Features: mkvmerge --engage native_mpeg4; ffmpeg bitstream filters h264_metadata, trace_headers, filter_units;
#           test encoders libx264, mpeg4, ac3, mov_text (only tests/smoke.sh needs these).
# Tested with Ubuntu 22.04: mkvtoolnix 65.0.0, ffmpeg 4.4.2, Python 3.10, jq 1.6.
# Install on Debian/Ubuntu: sudo apt install mkvtoolnix ffmpeg jq python3 file binutils e2fsprogs smartmontools lsof
# Exit codes: 0 = all required tools and features present, 1 = something required is missing.
set -u
usage() { sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0"; }
case "${1:-}" in -h|--help) usage; exit 0;; esac
miss=0
ver() { "$@" 2>&1 | head -1 | cut -c1-70; }
req() { if command -v "$1" >/dev/null 2>&1; then printf '[OK]   %-12s %s\n' "$1" "$(ver "${@:2}")"; else printf '[FAIL] %-12s missing (required)\n' "$1"; miss=1; fi; }
opt() { if command -v "$1" >/dev/null 2>&1; then printf '[OK]   %-12s %s\n' "$1" "$2"; else printf '[--]   %-12s missing (optional: %s)\n' "$1" "$2"; fi; }
req mkvmerge mkvmerge --version
req mkvinfo mkvinfo --version
req mkvextract mkvextract --version
req mkvpropedit mkvpropedit --version
req ffmpeg ffmpeg -version
req ffprobe ffprobe -version
req jq jq --version
req python3 python3 --version
req file file --version
req strings strings --version
req numfmt numfmt --version
req cmp cmp --version
req iconv iconv --version
req findmnt findmnt --version
if command -v python3 >/dev/null && ! python3 -c 'import sys; sys.exit(sys.version_info < (3, 8))'; then
  echo "[FAIL] python3 >= 3.8 required"; miss=1; fi
opt filefrag "badsector_map.sh"
opt journalctl "kernel disk-error checks in swap_in.sh / badsector_map.sh"
opt smartctl "SMART health data (run with sudo)"
opt lsof "find what keeps a drive busy before ejecting"
opt shellcheck "linting the shell scripts"
if command -v mkvmerge >/dev/null; then
  if mkvmerge --engage list 2>/dev/null | grep -q native_mpeg4; then echo "[OK]   mkvmerge --engage native_mpeg4"
  else echo "[FAIL] mkvmerge has no --engage native_mpeg4 (needed for MPEG-4 ASP fixes)"; miss=1; fi
fi
if command -v ffmpeg >/dev/null; then
  bsfs=$(ffmpeg -hide_banner -bsfs 2>/dev/null)
  for b in h264_metadata trace_headers filter_units; do
    if grep -qx "$b" <<< "$bsfs"; then echo "[OK]   ffmpeg bsf $b"; else echo "[FAIL] ffmpeg bsf $b missing"; miss=1; fi
  done
  enc=$(ffmpeg -hide_banner -encoders 2>/dev/null)
  for e in libx264 mpeg4 ac3 mov_text; do
    if grep -qE "^ [VAS.]{6} $e " <<< "$enc"; then echo "[OK]   ffmpeg encoder $e (tests only)"; else echo "[--]   ffmpeg encoder $e missing (tests/smoke.sh will skip what needs it)"; fi
  done
fi
if [ $miss = 0 ]; then echo "RESULT: all required tools present"; exit 0; else echo "RESULT: missing required tools (see above)"; exit 1; fi
