#!/usr/bin/env bash
# MPEG-4 Part 2 (DivX/Xvid) feature check: GMC warp points, quarter-pel, frame types, packed B-frames.
#
# Usage: mpeg4_asp_check.sh FILE [FRAMES=3000]
#
# Decodes the first FRAMES video frames with ffmpeg's debug output.
#   - "w:N" = GMC warp points. Samsung 2026: "GMC 2 and higher: Not supported" -> lossy re-encode, ASK USER.
#   - Packed B-frames (DivX tag ending in "p") are fixable losslessly: mkvmerge --engage native_mpeg4.
# For drop frames (0-7 byte packets) run packet_scan.py; for header details run mpeg4_vol.py.
# Exit codes: 0 = no unsupported feature seen, 1 = GMC with >= 2 warp points, 2 = usage error or missing tool.
set -u
usage() { sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0"; }
case "${1:-}" in -h|--help) usage; exit 0;; "") usage >&2; exit 2;; esac
command -v ffmpeg >/dev/null || { echo "missing tool: ffmpeg (run scripts/check_deps.sh)" >&2; exit 2; }
f="$1"; n="${2:-3000}"
[ -f "$f" ] || { echo "not found: $f" >&2; exit 2; }
echo "== $f"
out=$(ffmpeg -nostdin -hide_banner -debug 1 -i "$f" -map 0:v:0 -frames:v "$n" -f null - 2>&1)
echo "$out" | grep 'qp:' | grep -oE ' [hq]pel ' | sort | uniq -c | sed 's/^/  motion precision: /'
echo "$out" | grep 'qp:' | grep -oE ' w:[0-9]+ ' | sort | uniq -c | sed 's/^/  GMC warp points (w:N, N>=2 unsupported): /'
echo "$out" | grep -oE 'qp:[0-9]+ fc:[0-9,]+ [IPBS] ' | awk '{print $3}' | sort | uniq -c | sed 's/^/  frame type: /'
if echo "$out" | grep -q "packed B-frames"; then echo "  PACKED B-FRAMES: yes -> remux with: mkvmerge -o out.mkv --engage native_mpeg4 in.avi"
else echo "  packed B-frames: no"; fi
head -c 30000000 "$f" | strings -n 8 | grep -aoE 'DivX[0-9]+[A-Za-z0-9]*|XviD[0-9]+' | sort | uniq -c | sed 's/^/  encoder tag: /'
if echo "$out" | grep 'qp:' | grep -qE ' w:([2-9]|[1-9][0-9]+) '; then
  echo "  RED FLAG: GMC with >= 2 warp points is not supported by the TV -> re-encode needed, ASK USER"; exit 1
fi
exit 0
