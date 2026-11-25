#!/usr/bin/env bash
# Header-only inventory of media files: what is in them and what may stop the TV playing them.
#
# Usage: inspect.sh FILE_OR_DIR [...]
#
# Cheap: reads only the start of each file (safe on a failing drive).
# Per file it prints:
#   - container and tracks (codec, codec ID, language/IETF, name, default/forced/enabled, channels, size);
#   - attachments, chapters, Matroska DocType and tags;
#   - ffprobe stream details and the encoder string (x264/x265 options, DivX/Xvid tag);
#   - "RED FLAG:" lines (see docs/recipes.md for the fixes) and "NOTE:" lines.
# For a directory, it also lists external subtitle files (charset, whether the name matches a video).
# Exit codes: 0 = done (red flags are information, not failure), 2 = usage error or missing tool.
set -u
usage() { sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0"; }
case "${1:-}" in -h|--help) usage; exit 0;; "") usage >&2; exit 2;; esac
need() { for c in "$@"; do command -v "$c" >/dev/null 2>&1 || { echo "missing tool: $c (run scripts/check_deps.sh)" >&2; exit 2; }; done; }
need mkvmerge mkvinfo mkvextract ffprobe jq strings numfmt file

one() {
  local f="$1" j hdr="" enc flags=()
  echo "=================================================================="
  echo "== $f  ($(stat -c %s "$f" | numfmt --to=iec))"
  j=$(mkvmerge -J "$f" 2>/dev/null) || { echo "mkvmerge cannot identify it"; return; }
  echo "$j" | jq -r '"container: \(.container.type)  writer: \(.container.properties.writing_application // "-")  duration: \((.container.properties.duration // 0)/1e9|floor)s"'
  echo "$j" | jq -r '.tracks[] | "  #\(.id) \(.type) \(.codec) [\(.properties.codec_id // "-")] lang=\(.properties.language // "-")/\(.properties.language_ietf // "-") name=\(.properties.track_name // "-") def=\(.properties.default_track) forced=\(.properties.forced_track) en=\(.properties.enabled_track // "-") ch=\(.properties.audio_channels // "-") px=\(.properties.pixel_dimensions // "-")"'
  echo "$j" | jq -r '"attachments: \([.attachments[] | "\(.file_name) (\(.content_type), \(.size)B)"])  chapters: \(.chapters)"'
  ffprobe -v error -show_entries stream=index,codec_type,codec_name,codec_tag_string,profile,level,pix_fmt,field_order,width,height,r_frame_rate,bit_rate,channels,channel_layout,sample_rate -of compact=p=0 "$f" | sed 's/^/  ffprobe: /'
  if [ "$(echo "$j" | jq -r .container.type)" = "Matroska" ]; then
    hdr=$(mkvinfo "$f" 2>/dev/null | sed -n '1,/^|+ Cluster/p')
    echo "$hdr" | grep -E 'Document type (read )?version' | sed 's/^/  /'
    echo "  tags: $(mkvextract "$f" tags - 2>/dev/null | grep -oE '<Name>[^<]+' | sed 's/<Name>//' | sort -u | tr '\n' ' ')"
  fi
  enc=$(head -c 40000000 "$f" | strings -n 8 | grep -aoE '(x264 - core [0-9]+.*|x265 \(build.*|DivX[0-9]+[A-Za-z0-9]*|XviD[0-9]+)' | sort -u | head -3 | cut -c1-600)
  [ -n "$enc" ] && echo "  encoder: $enc"

  # ---- red flags (fixes: docs/recipes.md "Fix recipes")
  echo "$j" | jq -e '.tracks[] | select(.type=="audio" and (.codec|test("DTS|TrueHD|MLP|Opus|FLAC|Vorbis|PCM";"i")))' >/dev/null && flags+=("audio codec not on the safe list (DTS/TrueHD/Opus/FLAC/...) -> lossy conversion needed, ASK USER")
  echo "$j" | jq -e '.tracks[] | select(.type=="subtitles" and (.properties.codec_id // "" | test("ASS|SSA|PGS|VOBSUB|HDMV";"i")))' >/dev/null && flags+=("ASS/SSA/PGS/VobSub subtitles -> drop, or convert (lossy: ASK USER)")
  echo "$j" | jq -e '.tracks[] | select(.type=="video" and (.codec|test("jpeg|png";"i")))' >/dev/null && flags+=("picture 'video' track (cover art or chapter thumbnails) -> keep only the real video track: mkvmerge -d <TID>")
  echo "$j" | jq -e '.tracks[] | select(.type=="video" and (.codec|test("AVC|HEVC|MPEG-4p2|MPEG-1|MPEG-2|AV1|VP8|VP9|jpeg|png";"i")|not))' >/dev/null && flags+=("video codec not in the 2026 list (VC-1/WMV/RealVideo/...) -> re-encode needed, ASK USER")
  echo "$j" | jq -e '.tracks[] | select(.properties.enabled_track == false)' >/dev/null && flags+=("track(s) marked disabled (Apple alternate groups) -> --track-enabled-flag <TID>:1")
  echo "$j" | jq -e '.attachments | length > 0' >/dev/null && flags+=("has attachments (cover/fonts) -> remux with --no-attachments")
  echo "$j" | jq -e '[.tracks[].properties.language_ietf] | map(select(.)) | length > 0' >/dev/null && flags+=("IETF BCP47 language elements -> --disable-language-ietf")
  [ -n "$hdr" ] && echo "$hdr" | grep -qiE 'content (encoding|compression)|header (removal|stripping)' && flags+=("Matroska content compression/header stripping -> remux with --compression -1:none")
  ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt,profile -of csv=p=0 "$f" | grep -qiE '10|12|422|444' && flags+=("video is not 8-bit 4:2:0 (H.264 High10/4:2:2 is NOT supported; HEVC Main10 is)")
  ffprobe -v error -select_streams v:0 -show_entries stream=field_order -of csv=p=0 "$f" | grep -qiE 'tt|bb|tb|bt' && flags+=("interlaced video")
  echo "$enc" | grep -qE 'DivX[0-9]+.*p$' && flags+=("DivX packed bitstream (packed B-frames) -> mkvmerge --engage native_mpeg4")
  case "$f" in *.m4v|*.M4V) flags+=(".m4v extension is not in Samsung's list -> remux to MKV");; esac
  [ "$(echo "$j" | jq -r .container.type)" = "AVI" ] && [ "$(stat -c %s "$f")" -gt 2147483647 ] && flags+=("AVI > 2 GiB (OpenDML) -> remux to MKV")
  if [ ${#flags[@]} -gt 0 ]; then printf '  RED FLAG: %s\n' "${flags[@]}"; else echo "  no header-level red flags (still run h264_sps_report.py for H.264, mpeg4_asp_check.sh for DivX/Xvid)"; fi
  if echo "$j" | jq -e '.tracks[] | select(.type=="video" and (.codec|test("MPEG-4p2")))' >/dev/null; then
    echo "  NOTE: MPEG-4 ASP (DivX/Xvid). If the TV refuses it, store it natively in MKV: --engage native_mpeg4 (docs/recipes.md)"
  fi
}

# External subtitle files: the TV only matches "<video name>.srt" exactly; non-UTF-8 text depends on a TV setting.
subs() {
  local s enc base m v shown=""
  while IFS= read -r -d '' s; do
    [ -n "$shown" ] || { echo "=================================================================="; echo "== external subtitle files in $1"; shown=1; }
    enc=$(file -b --mime-encoding "$s"); base="${s%.*}"; m=""
    for v in "$base".{mkv,mp4,avi,m4v,ts,m2ts,mov,webm,wmv}; do [ -e "$v" ] && m=$(basename "$v"); done
    echo "  $(basename "$s")  charset=$enc  $([ -n "$m" ] && echo "matches $m" || echo "NO video with the same name")"
    [ -z "$m" ] && echo "    RED FLAG: name doesn't match any video -> the TV won't pick it up; mux it into an MKV"
    case "$enc" in utf-8|us-ascii) ;; *) echo "    RED FLAG: charset $enc (Russian 8-bit is nearly always cp1251: check with iconv -f cp1251 -t utf-8) -> mux with --sub-charset 0:cp1251";; esac
    case "$s" in *.[aA][sS][sS]|*.[sS][sS][aA]) echo "    RED FLAG: ASS/SSA not supported by the TV (converting to SRT loses positions/styles: ASK USER)";; esac
  done < <(find "$1" -maxdepth 1 -type f \( -iname '*.srt' -o -iname '*.ass' -o -iname '*.ssa' -o -iname '*.sub' -o -iname '*.idx' -o -iname '*.vtt' -o -iname '*.smi' \) -print0 | sort -z)
}

for a in "$@"; do
  if [ -d "$a" ]; then
    while IFS= read -r -d '' f; do one "$f"; done < <(find "$a" -maxdepth 1 -type f \( -iname '*.mkv' -o -iname '*.mp4' -o -iname '*.avi' -o -iname '*.m4v' -o -iname '*.ts' -o -iname '*.m2ts' -o -iname '*.mov' -o -iname '*.webm' -o -iname '*.wmv' \) -print0 | sort -z)
    subs "$a"
  elif [ -f "$a" ]; then one "$a"
  else echo "not found: $a" >&2; exit 2; fi
done
