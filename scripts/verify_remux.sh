#!/usr/bin/env bash
# Prove that NEW is a lossless remux of ORIG. The gate before any fixed file replaces an original.
#
# Usage: verify_remux.sh ORIG NEW [WORKDIR]
#        ALLOW_ADDED_SUBS=1 verify_remux.sh ORIG NEW [WORKDIR]
#          -> NEW has extra subtitle tracks muxed in from external files: subtitle tracks are left out of
#             checks 1+2 and listed instead; prove each of them with srt_compare.py / tx3g_compare.py.
#
# Checks:
#  1. track list: same container family -> type/codec/lang/name/flags/channels/size must match
#     (attachments are listed separately - dropping a cover is expected);
#     different families (AVI/MP4 -> MKV) -> only type/codec/channels/size are compared.
#  2. audio+subtitle payload:
#     - same family: per-packet framemd5 (dts, pts, duration, size, md5) must be identical;
#     - otherwise:   per-stream hash of all packet data (packetization-independent). If a hash differs, NEW is
#       checked for being ORIG minus an incomplete first/last frame ("[OK~]", harmless).
#  3. video: MD5 of every DECODED frame must be identical (bit-exact pictures even when headers were rewritten).
#     Frame timestamps are compared too:
#       [OK]   identical                      -> plain remux (incl. AVI->MKV in mkvmerge's default VFW mode);
#       [NOTE] one constant offset            -> expected for Xvid/DivX with B-frames AVI->MKV --engage native_mpeg4
#                                                (1 frame: AVI has no PTS). A spread <= 2 ms counts as constant
#                                                (Matroska stores whole ms; 23.976/24 fps sources show +-1 ms);
#       [FAIL] non-uniform offset             -> A/V sync would shift mid-file (native mode + drop frames:
#                                                re-mux with a timestamp file from ts_v2_from_frames.py).
#     If only consecutive duplicate frames differ, "[OK*]" is printed: check A/V sync on a sample.
#  4. decoder/demuxer messages of both sides are shown ("Input/output error" => check the source drive).
# Both files are read in full, in parallel. WORKDIR keeps v_orig/v_new ("seconds,md5" per frame) for later use.
# Exit codes: 0 = RESULT: VERIFIED, 1 = RESULT: FAILED, 2 = usage error or missing tool.
set -u
usage() { sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0"; }
case "${1:-}" in -h|--help) usage; exit 0;; esac
[ $# -ge 2 ] || { usage >&2; exit 2; }
for c in mkvmerge ffmpeg ffprobe jq; do command -v "$c" >/dev/null || { echo "missing tool: $c (run scripts/check_deps.sh)" >&2; exit 2; }; done
ORIG="$1"; NEW="$2"; OUT="${3:-$(mktemp -d)}"; mkdir -p "$OUT"; ok=1
for f in "$ORIG" "$NEW"; do [ -f "$f" ] || { echo "not found: $f" >&2; exit 2; }; done
ctype() { mkvmerge -J "$1" | jq -r .container.type; }
same=1; [ "$(ctype "$ORIG")" = "$(ctype "$NEW")" ] || same=0
sel='.tracks[]'; smap='-map 0:s?'
if [ "${ALLOW_ADDED_SUBS:-0}" = 1 ]; then
  sel='.tracks[] | select(.type != "subtitles")'; smap=''
  echo "subtitle tracks excluded from checks 1+2 (ALLOW_ADDED_SUBS=1); NEW has:"
  mkvmerge -J "$NEW" | jq -r '.tracks[] | select(.type == "subtitles") | "  track \(.id): \(.codec) lang=\(.properties.language) name=\(.properties.track_name // "-") default=\(.properties.default_track) forced=\(.properties.forced_track)"'
fi
if [ $same = 1 ]; then
  q='['"$sel"' | {type, codec, lang: .properties.language, name: .properties.track_name, def: .properties.default_track, forced: .properties.forced_track, en: .properties.enabled_track, ch: .properties.audio_channels, dim: .properties.pixel_dimensions, disp: .properties.display_dimensions}]'
else
  q='['"$sel"' | {type, codec, ch: .properties.audio_channels, dim: .properties.pixel_dimensions}]'
fi
mkvmerge -J "$ORIG" | jq -c "$q" > "$OUT/tracks_orig.json"; mkvmerge -J "$NEW" | jq -c "$q" > "$OUT/tracks_new.json"
if cmp -s "$OUT/tracks_orig.json" "$OUT/tracks_new.json"; then echo "[OK] track list identical (same container family: $same)"
else echo "[FAIL] track list differs"; diff <(jq . "$OUT/tracks_orig.json") <(jq . "$OUT/tracks_new.json"); ok=0; fi
for k in chapters attachments; do echo "$k: orig=$(mkvmerge -J "$ORIG" | jq -c ".$k") new=$(mkvmerge -J "$NEW" | jq -c ".$k")"; done
echo "duration: orig=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$ORIG") new=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$NEW")"

# 2. audio + subtitles
if [ $same = 1 ]; then
  as() { ffmpeg -nostdin -v error -i "$1" -map 0:a? $smap -c copy -f framemd5 - 2>"$2.err" | grep -v '^#' > "$2"; }
  what="per-packet framemd5"
else
  as() { ffmpeg -nostdin -v error -i "$1" -map 0:a? $smap -c copy -f streamhash -hash md5 - 2>"$2.err" > "$2"; }
  what="per-stream payload hash"
fi
as "$ORIG" "$OUT/as_orig" & as "$NEW" "$OUT/as_new" & wait
if [ ! -s "$OUT/as_orig" ] && [ ! -s "$OUT/as_new" ]; then echo "[--] no audio/subtitle streams"
elif cmp -s "$OUT/as_orig" "$OUT/as_new"; then echo "[OK] audio+subtitles identical ($what, $(wc -l < "$OUT/as_new") lines)"
else
  echo "[DIFF] audio/subtitles differ ($what):"; diff "$OUT/as_orig" "$OUT/as_new" | head
  unexplained=1
  if [ $same = 0 ] && [ "$(wc -l < "$OUT/as_orig")" = "$(wc -l < "$OUT/as_new")" ]; then
    # (streamhash index n = n-th mapped output stream; audio is mapped first, so audio n = input 0:a:n)
    # Common harmless case: the source track starts/ends with an INCOMPLETE frame (e.g. a 192-byte piece of a
    # 768-byte AC-3 frame at the end of an AVI); mkvmerge's parser drops it. Check NEW = ORIG minus head/tail bytes.
    unexplained=0
    for i in $(paste -d' ' "$OUT/as_orig" "$OUT/as_new" | awk '$1 != $2 { split($1, a, ","); print a[2] ":" a[1] }'); do
      t=${i%%:*}; n=${i#*:}; [ "$t" = a ] || { unexplained=1; continue; }
      ffmpeg -nostdin -v error -i "$ORIG" -map 0:a:$n -c copy -f data - > "$OUT/raw_o" 2>/dev/null
      ffmpeg -nostdin -v error -i "$NEW"  -map 0:a:$n -c copy -f data - > "$OUT/raw_n" 2>/dev/null
      so=$(stat -c %s "$OUT/raw_o"); sn=$(stat -c %s "$OUT/raw_n")
      if [ "$sn" -lt "$so" ] && cmp -s "$OUT/raw_n" <(head -c "$sn" "$OUT/raw_o"); then
        echo "[OK~] output stream $n (audio): NEW = ORIG minus its LAST $((so - sn)) bytes (incomplete final frame dropped) - harmless"
      elif [ "$sn" -lt "$so" ] && cmp -s "$OUT/raw_n" <(tail -c "$sn" "$OUT/raw_o"); then
        echo "[OK~] output stream $n (audio): NEW = ORIG minus its FIRST $((so - sn)) bytes (incomplete first frame dropped) - harmless, but check A/V sync"
      else echo "[FAIL] audio stream $n: payload differs beyond a dropped incomplete first/last frame"; unexplained=1; fi
      rm -f "$OUT/raw_o" "$OUT/raw_n"
    done
  fi
  if [ $unexplained = 0 ]; then echo "[OK~] all audio differences explained"; else echo "[FAIL] audio/subtitles differ"; ok=0; fi
fi

# 3. decoded video
# -idct simple: ffmpeg auto-picks the MPEG-4 ASP IDCT from the container FourCC (DIVX/XVID in AVI vs none
# in native MKV), which changes pixels slightly although the bitstream is the same. Pinning it makes the
# comparison container-independent (ignored by H.264/HEVC decoders).
# framemd5 lines -> "seconds,md5" (pts * the "#tb 0:" time base, which can differ between containers)
vh() { ffmpeg -nostdin -v error -idct simple -i "$1" -map 0:v:0 -vsync passthrough -f framemd5 - 2>"$2.err" |
  awk -F, '/^#tb 0:/ { split($0, a, " "); split(a[3], r, "/"); tb = r[1] / r[2]; next } /^#/ { next }
           { gsub(/ /, ""); printf "%.6f,%s\n", $3 * tb, $6 }' > "$2"; }
vh "$ORIG" "$OUT/v_orig" & vh "$NEW" "$OUT/v_new" & wait
cut -d, -f2 "$OUT/v_orig" > "$OUT/vh_orig"; cut -d, -f2 "$OUT/v_new" > "$OUT/vh_new"
no=$(wc -l < "$OUT/vh_orig"); nn=$(wc -l < "$OUT/vh_new")
if [ "$no" -gt 0 ] && cmp -s "$OUT/vh_orig" "$OUT/vh_new"; then
  echo "[OK] decoded video identical ($nn frames)"
  offs=$(paste -d, <(cut -d, -f1 "$OUT/v_orig") <(cut -d, -f1 "$OUT/v_new") |
    awk -F, '{ d = int(($1 - $2) * 1000 + (($1 >= $2) ? 0.5 : -0.5)); c[(d > 0 ? "+" : "") d]++ } END { for (k in c) printf "%s ms x %d frames; ", k, c[k] }')
  # spread = max - min offset in ms. Matroska stores whole ms, so a 23.976/24 fps source shows +-1 ms rounding jitter.
  spread=$(paste -d, <(cut -d, -f1 "$OUT/v_orig") <(cut -d, -f1 "$OUT/v_new") |
    awk -F, '{ d = ($1 - $2) * 1000; if (NR == 1 || d < mn) mn = d; if (NR == 1 || d > mx) mx = d } END { printf "%d", mx - mn + 0.5 }')
  case "$offs" in
    "0 ms x $nn frames; ") echo "[OK] frame timestamps identical" ;;
    *" frames; ") n_off=$(grep -o ';' <<< "$offs" | wc -l)
      if [ "$n_off" = 1 ] || [ "$spread" -le 2 ]; then echo "[NOTE] constant frame-timestamp offset (orig - new): ${offs%; } (spread ${spread} ms; <= 2 ms is Matroska's 1 ms rounding) - expected only for Xvid/DivX B-frames AVI->MKV (1 frame)" | cut -c1-400
      else
        at=$(paste -d, <(cut -d, -f1 "$OUT/v_orig") <(cut -d, -f1 "$OUT/v_new") | awk -F, 'NR == 1 { p = $1 - $2 } { if (($1 - $2) - p > 0.001 || p - ($1 - $2) > 0.001) { printf "frame %d (%.3f s)", NR, $1; exit } }')
        echo "[FAIL] frame timestamps differ non-uniformly (A/V sync would change mid-file), first change at $at: $offs" | cut -c1-400
        echo "       e.g. --engage native_mpeg4 drops Xvid/DivX not-coded 'drop' frames and closes their time slot: re-mux with --timestamps 0:ts.txt from scripts/ts_v2_from_frames.py"; ok=0; fi ;;
  esac
elif [ "$no" -gt 0 ] && cmp -s <(uniq "$OUT/vh_orig") <(uniq "$OUT/vh_new"); then echo "[OK*] decoded video identical except repeated (duplicate) frames: orig $no / new $nn frames - check A/V sync on a sample"
else
  first=$(cmp "$OUT/vh_orig" "$OUT/vh_new" 2>/dev/null | grep -oE 'line [0-9]+')
  echo "[FAIL] decoded video differs (orig $no frames, new $nn frames, first difference at ${first:-?})"; ok=0
fi
for e in "$OUT"/*.err; do [ -s "$e" ] && { echo "[WARN] messages in $(basename "$e"):"; sort "$e" | uniq -c | sort -rn | head -5; }; done
grep -qs 'Input/output error' "$OUT"/*.err && echo "[WARN] I/O errors while reading - run: journalctl -k | grep -i 'medium error'"
if [ $ok = 1 ]; then echo "RESULT: VERIFIED  (workdir $OUT)"; exit 0; else echo "RESULT: FAILED  (workdir $OUT)"; exit 1; fi
