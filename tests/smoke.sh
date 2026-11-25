#!/usr/bin/env bash
# Smoke tests: build tiny synthetic media with ffmpeg and run every script on it, including negative cases.
#
# Usage: tests/smoke.sh                 (from anywhere)
#        KEEP=1 tests/smoke.sh          keep the work directory for inspection
#
# Needs the required tools (scripts/check_deps.sh) plus the ffmpeg encoders libx264, mpeg4, ac3, mov_text.
# Takes well under a minute. No network, no real movie files: everything happens in a temporary directory.
# Every script change must keep this green; add a case here for every new script or behavior.
# Exit codes: 0 = all tests passed, 1 = at least one failed.
set -u
usage() { sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0"; }
case "${1:-}" in -h|--help) usage; exit 0;; esac
S=$(cd "$(dirname "$0")/../scripts" && pwd)
T=$(mktemp -d)
if [ "${KEEP:-0}" = 1 ]; then echo "work dir: $T"; else trap 'rm -rf "$T"' EXIT; fi
cd "$T" || exit 1
pass=0; fail=0; skip=0; n=0

# t NAME EXPECTED_EXIT [REGEX] -- COMMAND...   (REGEX must match the command's combined output)
t() {
  local name="$1" want="$2" pat="" rc log
  shift 2
  if [ "$1" != -- ]; then pat="$1"; shift; fi
  shift
  n=$((n + 1)); log="$T/log.$n"
  "$@" > "$log" 2>&1; rc=$?
  if [ "$rc" = "$want" ] && { [ -z "$pat" ] || grep -qE -- "$pat" "$log"; }; then
    echo "PASS  $name"; pass=$((pass + 1))
  else
    echo "FAIL  $name (exit $rc, wanted $want${pat:+, pattern /$pat/})"; tail -15 "$log" | sed 's/^/      | /'; fail=$((fail + 1))
  fi
}
skip() { echo "SKIP  $1"; skip=$((skip + 1)); }
ff() { ffmpeg -nostdin -v error -y "$@"; }
py() { python3 -I "$S/$1" "${@:2}"; }

# ---------------------------------------------------------------- tools and help texts
t "check_deps.sh: required tools present" 0 "RESULT: all required" -- "$S/check_deps.sh"
for s in "$S"/*; do t "$(basename "$s") --help" 0 "[Uu]sage" -- "$s" --help; done

# ---------------------------------------------------------------- synthetic media
# Xvid-like AVI: MPEG-4 ASP with B-frames, AC-3 2.0 + 5.1, 6 s at 25 fps (ffmpeg writes a plain 40-byte header)
ff -f lavfi -i testsrc2=size=320x240:rate=25:duration=6 -f lavfi -i sine=frequency=440:sample_rate=48000:duration=6 \
   -f lavfi -i sine=frequency=660:sample_rate=48000:duration=6 -map 0 -map 1 -map 2 -c:v mpeg4 -vtag XVID -bf 2 -g 50 \
   -q:v 4 -c:a ac3 -b:a:0 192k -ac:a:0 2 -b:a:1 448k -ac:a:1 6 movie.avi || { echo "cannot generate test media"; exit 1; }
ff -i movie.avi -map 0 -c copy lavf.avi            # stream copy: ffmpeg adds the VOL as extradata (lavf-style header)
ff -f lavfi -i testsrc2=size=320x240:rate=25:duration=2 -c:v mpeg4 -vtag XVID -bf 2 -flags +global_header gh.avi  # no in-band VOL
printf '1\r\n00:00:01,000 --> 00:00:02,500\r\nПривет, мир\r\n\r\n2\r\n00:00:03,000 --> 00:00:04,000\r\nВторая строка\r\n' |
  iconv -f utf-8 -t cp1251 > movie.RUS.Forced.srt
printf '1\n00:00:01,000 --> 00:00:02,500\nHello, <i>world</i>\n\n2\n00:00:03,000 --> 00:00:04,000\nSecond line\n' > movie.ENG.srt

# ---------------------------------------------------------------- header-only analysis
t "inspect.sh: lists the AVI" 0 "container: AVI" -- "$S/inspect.sh" "$T"
t "inspect.sh: external SRT name mismatch flagged" 0 "RED FLAG: name doesn't match" -- "$S/inspect.sh" "$T"
t "inspect.sh: cp1251 SRT flagged" 0 "RED FLAG: charset" -- "$S/inspect.sh" "$T"
t "inspect.sh: missing file -> exit 2" 2 -- "$S/inspect.sh" "$T/nope.mkv"
t "avi_headers.py: plain header" 0 "biSize=40 .*extradata=0" -- py avi_headers.py movie.avi
t "avi_headers.py: lavf header with extradata" 0 "biSize=[0-9]+ .*extradata=[1-9]" -- py avi_headers.py lavf.avi
t "avi_headers.py: decodes WAVEFORMATEXTENSIBLE AC-3" 0 "EXTENSIBLE: AC-3" -- py avi_headers.py movie.avi
t "avi_headers.py: not an AVI -> exit 2" 2 -- py avi_headers.py movie.ENG.srt
t "mpeg4_vol.py: VOS/VOL decoded" 0 "Advanced Simple" -- py mpeg4_vol.py movie.avi
t "mpeg4_vol.py: no VOL -> exit 2" 2 -- py mpeg4_vol.py movie.ENG.srt

# ---------------------------------------------------------------- full-read analysis
t "mpeg4_asp_check.sh: not packed" 0 "packed B-frames: no" -- "$S/mpeg4_asp_check.sh" movie.avi
t "packet_scan.py: clean read, no drop frames" 0 "drop frames\): none" -- py packet_scan.py movie.avi --keep-csv movie.pk.csv
t "packet_scan.py: CSV kept" 0 -- test -s movie.pk.csv

# ---------------------------------------------------------------- AVI -> MKV remuxes and verification
mkvmerge -q -o vfw.mkv movie.avi
t "verify_remux.sh: VFW-mode remux, timestamps identical" 0 "frame timestamps identical" -- "$S/verify_remux.sh" movie.avi vfw.mkv v_vfw
mkvmerge -q -o native.mkv --engage native_mpeg4 movie.avi
t "verify_remux.sh: native remux, constant 1-frame offset" 0 "NOTE\] constant frame-timestamp offset.*\+40 ms" -- "$S/verify_remux.sh" movie.avi native.mkv v_native
t "ts_v2_from_frames.py: 150 frames, no gaps" 0 "150 frames.*gaps > 1.5 frames: 0" -- bash -c "python3 -I '$S/ts_v2_from_frames.py' movie.avi > ts.txt"
t "ts_v2_from_frames.py: reuses verify's v_orig" 0 "shift 40 ms" -- bash -c "python3 -I '$S/ts_v2_from_frames.py' movie.avi --from-verify v_native/v_orig > ts2.txt"
t "ts file from decode == ts file from v_orig" 0 -- cmp ts.txt ts2.txt
mkvmerge -q -o native_ts.mkv --engage native_mpeg4 --timestamps 0:ts.txt movie.avi
t "verify_remux.sh: native remux with timestamp file" 0 "NOTE\] constant" -- "$S/verify_remux.sh" movie.avi native_ts.mkv v_native_ts
awk 'NR > 51 && !/^#/ { $1 += 40 } { print }' ts.txt > ts_gap.txt    # simulate a closed/opened slot mid-file
mkvmerge -q -o native_gap.mkv --engage native_mpeg4 --timestamps 0:ts_gap.txt movie.avi
t "verify_remux.sh: mid-file timing shift -> FAILED" 1 "non-uniformly" -- "$S/verify_remux.sh" movie.avi native_gap.mkv v_gap
mkvmerge -q -o swapped.mkv --track-order 0:0,0:2,0:1 movie.avi
t "verify_remux.sh: swapped audio tracks -> FAILED" 1 "track list differs" -- "$S/verify_remux.sh" movie.avi swapped.mkv v_swap
t "verify_remux.sh: missing argument -> exit 2" 2 -- "$S/verify_remux.sh" movie.avi

# ---------------------------------------------------------------- external subtitles
mkvmerge -q -o subs.mkv movie.avi --language 0:rus --sub-charset 0:cp1251 --forced-display-flag 0:1 --track-name 0:Forced \
  movie.RUS.Forced.srt --language 0:eng --default-track-flag 0:0 movie.ENG.srt
export ALLOW_ADDED_SUBS=1
t "verify_remux.sh: ALLOW_ADDED_SUBS" 0 "RESULT: VERIFIED" -- "$S/verify_remux.sh" movie.avi subs.mkv v_subs
unset ALLOW_ADDED_SUBS
t "srt_compare.py: cp1251 track identical" 0 "\[OK\] 2 cues identical" -- py srt_compare.py movie.RUS.Forced.srt subs.mkv 3 --charset cp1251
t "srt_compare.py: UTF-8 track identical" 0 "\[OK\] 2 cues identical" -- py srt_compare.py movie.ENG.srt subs.mkv 4
t "srt_compare.py: wrong charset -> exit 2" 2 -- py srt_compare.py movie.RUS.Forced.srt subs.mkv 3
mkvmerge -q -o subs_nocs.mkv movie.avi movie.RUS.Forced.srt > /dev/null 2>&1   # forgot --sub-charset (mkvmerge only warns)
t "srt_compare.py: muxed without --sub-charset -> FAIL" 1 "\[FAIL\]" -- py srt_compare.py movie.RUS.Forced.srt subs_nocs.mkv 3 --charset cp1251
t "srt_compare.py: not a subtitle track -> exit 2" 2 -- py srt_compare.py movie.ENG.srt subs.mkv 0

# ---------------------------------------------------------------- AVI header patch
cp lavf.avi patched.avi
t "avi_fix_bih.py: patches the lavf header" 0 "\[OK\] patched" -- py avi_fix_bih.py patched.avi
t "avi_fix_bih.py: only header bytes changed" 0 -- bash -c "test -n \"\$(cmp -l lavf.avi patched.avi)\" && cmp -l lavf.avi patched.avi | awk '\$1 > 4096 { exit 1 }'"
t "avi_fix_bih.py: decoded video unchanged" 0 -- bash -c "cmp <(ffmpeg -v error -i lavf.avi -map 0:v -f framemd5 - | grep -v '^#') <(ffmpeg -v error -i patched.avi -map 0:v -f framemd5 - | grep -v '^#')"
t "avi_fix_bih.py: second run is a no-op" 0 "nothing to do" -- py avi_fix_bih.py patched.avi
t "avi_fix_bih.py: refuses without in-band VOL" 1 "no in-band VOL" -- py avi_fix_bih.py gh.avi

# ---------------------------------------------------------------- H.264: VUI timing (the Prometheus/Covenant defect)
if ff -f lavfi -i testsrc2=size=320x240:rate=24000/1001:duration=4 -c:v libx264 -preset ultrafast -bf 2 \
      -bsf:v h264_metadata=tick_rate=180000:fixed_frame_rate_flag=0 bad_vui.mkv 2>/dev/null; then
  ff -i bad_vui.mkv -c copy bad_vui.mp4
  t "h264_sps_report.py: 90000 fps VUI flagged (MKV)" 1 "VUI_FPS': 90000" -- py h264_sps_report.py bad_vui.mkv
  t "h264_sps_report.py: 90000 fps VUI flagged (MP4 avcC)" 1 "absurd frame rate" -- py h264_sps_report.py bad_vui.mp4
  mkvmerge -q -o fixed_vui.mkv --fix-bitstream-timing-information 0:1 bad_vui.mkv
  t "h264_sps_report.py: fixed file is clean" 0 "VUI_FPS': 23.976" -- py h264_sps_report.py fixed_vui.mkv
  t "verify_remux.sh: VUI fix is lossless" 0 "RESULT: VERIFIED" -- "$S/verify_remux.sh" bad_vui.mkv fixed_vui.mkv v_vui
else skip "H.264 tests (no libx264)"; fi

# ---------------------------------------------------------------- MP4 timed text (tx3g)
if ff -f lavfi -i testsrc2=size=320x240:rate=25:duration=5 -i movie.ENG.srt -map 0 -map 1 -c:v libx264 -preset ultrafast \
      -c:s mov_text tx.mp4 2>/dev/null; then
  ff -i tx.mp4 -map 0:s:0 -c:s srt tx_raw.srt
  sed -E 's#<font size="[0-9]+">##g; s#</font>##g' tx_raw.srt > tx.srt
  t "tx3g_compare.py: converted SRT identical" 0 "\[OK\] every cue identical" -- py tx3g_compare.py tx.mp4 0 tx.srt
  sed 's/Second line/Second lime/' tx.srt > tx_bad.srt
  t "tx3g_compare.py: changed text -> FAIL" 1 "\[FAIL\]" -- py tx3g_compare.py tx.mp4 0 tx_bad.srt
else skip "tx3g tests (no libx264/mov_text)"; fi

# ---------------------------------------------------------------- swap in (same filesystem, temp dirs)
mkdir -p lib backup && cp movie.avi lib/Movie.avi
t "swap_in.sh: swaps and reads back" 0 "\[OK\] read-back from disk identical" -- "$S/swap_in.sh" native_ts.mkv lib/Movie.avi backup
t "swap_in.sh: new file in place, original in backup" 0 -- bash -c "test -f lib/Movie.mkv && test ! -e lib/Movie.avi && find backup -name Movie.avi | grep -q ."
t "swap_in.sh: second run refused" 1 "target not found" -- "$S/swap_in.sh" native_ts.mkv lib/Movie.avi backup

# ---------------------------------------------------------------- bad-sector mapping (needs a block device + FIEMAP)
dev=$(findmnt -no SOURCE -T "$T" 2>/dev/null); pn=$(basename "$dev")
phys=$(filefrag -v movie.avi 2>/dev/null | awk '/^ *0:/ { gsub(/\.\./, " "); gsub(/:/, ""); print $4; exit }')
if [ -e "/sys/class/block/$pn/start" ] && [ -n "$phys" ]; then
  bs=$(filefrag -v movie.avi | sed -nE 's/.* blocks? of ([0-9]+) bytes.*/\1/p')
  lba=$(( $(cat "/sys/class/block/$pn/start") + phys * bs / 512 + 1 ))
  t "badsector_map.sh: LBA inside the file found" 1 "LBA $lba -> .*movie.avi" -- env BAD_LBAS="$lba" "$S/badsector_map.sh" "$dev" movie.avi
  t "badsector_map.sh: LBA outside the files" 0 "outside the given files" -- env BAD_LBAS=1 "$S/badsector_map.sh" "$dev" movie.avi
else skip "badsector_map.sh (temp dir is not on a block device with FIEMAP)"; fi
t "badsector_map.sh: unknown partition -> exit 2" 2 -- "$S/badsector_map.sh" /dev/does-not-exist1 movie.avi

echo "---- $pass passed, $fail failed, $skip skipped"
[ "$fail" = 0 ]
