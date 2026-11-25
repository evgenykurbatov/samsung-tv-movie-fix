#!/usr/bin/env bash
# Map bad sectors (LBAs) to the files that contain them. Metadata-only (filefrag/FIEMAP): reads no file data.
#
# Usage: badsector_map.sh /dev/sdX1 FILE_OR_DIR [...]
#        BAD_LBAS="n1 n2 ..." badsector_map.sh /dev/sdX1 FILE_OR_DIR [...]
#
# LBAs come from BAD_LBAS (e.g. SMART's LBA_of_first_error) or, by default, from the kernel log
# ("critical medium error, dev sdX, sector N"; reading it may need membership in the adm/systemd-journal group).
# Formula: fs_block = (LBA - partition_start) * 512 / fs_block_size; filefrag prints extents in fs blocks.
# Tested on ntfs3 and ext4. Files copied in parallel end up interleaved on disk.
# Exit codes: 0 = no listed LBA lies inside the given files, 1 = at least one does, 2 = usage error / no such partition.
set -u
usage() { sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0"; }
case "${1:-}" in -h|--help) usage; exit 0;; esac
[ $# -ge 2 ] || { usage >&2; exit 2; }
command -v filefrag >/dev/null || { echo "missing tool: filefrag (package e2fsprogs)" >&2; exit 2; }
part="$1"; shift
pname=$(basename "$part")
[ -e "/sys/class/block/$pname/start" ] || { echo "no such partition: $part (drive unplugged?)" >&2; exit 2; }
disk=$(basename "$(readlink -f "/sys/class/block/$pname/..")")
start=$(cat "/sys/class/block/$pname/start")
if [ -n "${BAD_LBAS:-}" ]; then mapfile -t bad < <(printf '%s\n' $BAD_LBAS | sort -un)
else mapfile -t bad < <(journalctl -k --no-pager 2>/dev/null | grep -oE "dev $disk, sector [0-9]+" | awk '{print $4}' | sort -un); fi
echo "partition $part starts at LBA $start; bad LBAs to map on $disk: ${#bad[@]}"
[ ${#bad[@]} -eq 0 ] && exit 0
lst=$(mktemp); res=$(mktemp); trap 'rm -f "$lst" "$res"' EXIT
printf "%s\n" "${bad[@]}" > "$lst"
find "$@" -type f -print0 | while IFS= read -r -d '' f; do
  filefrag -v "$f" 2>/dev/null | awk -v name="$f" -v start="$start" -v list="$lst" '
    BEGIN { while ((getline s < list) > 0) bad[++n] = s }
    # "(383494 blocks of 4096 bytes)" - singular "block" for 1-block files (e.g. small .srt)
    / blocks? of [0-9]+ bytes/ { s = $0; sub(/.* blocks? of /, "", s); sub(/ bytes.*/, "", s); bs = s + 0 }
    /^ *[0-9]+:/ && bs > 0 { gsub(/\.\./, " "); gsub(/:/, "");
      for (i = 1; i <= n; i++) { b = int((bad[i] - start) * 512 / bs);
        if (b >= $4 && b <= $5) printf "LBA %s -> %s @ offset %.1f MB\n", bad[i], name, (($2 + (b - $4)) * bs) / 1e6 } }'
done | tee "$res"
echo "LBAs not listed above are outside the given files (free space or filesystem metadata)."
[ -s "$res" ] && exit 1
exit 0
