#!/usr/bin/env bash
# Put a verified fixed file in place of the original, keeping the original as a backup.
#
# Usage: swap_in.sh NEW_FILE TARGET_FILE BACKUP_ROOT
#   NEW_FILE     verified remux (in your work folder on a fast local disk)
#   TARGET_FILE  original file on the movie drive (MOVED to the backup, not deleted)
#   BACKUP_ROOT  folder on the SAME filesystem as TARGET_FILE (so the move is an instant rename), e.g.
#                <drive>/_backup_originals ; the path below the mount point is kept.
#
# The new file's name is TARGET_FILE's name with NEW_FILE's extension (.avi -> .mkv).
# Steps: kernel-error baseline -> move original to backup -> copy -> fsync -> drop both files from the
# page cache -> byte compare (so the compare really reads the disk) -> kernel-error check.
# NEW_FILE is kept; delete it only after the user confirmed playback on the TV.
# Refuses to overwrite an existing backup or destination.
# Exit codes: 0 = swapped and read back identical, 1 = refused or read-back differs (original stays in the backup),
#             2 = usage error.
set -euo pipefail
usage() { sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0"; }
case "${1:-}" in -h|--help) usage; exit 0;; esac
[ $# -eq 3 ] || { usage >&2; exit 2; }
NEW="$1"; TGT="$2"; BROOT="$3"
[ -f "$TGT" ] || { echo "target not found: $TGT (already swapped?) - aborting"; exit 1; }
[ -f "$NEW" ] || { echo "new file not found: $NEW - aborting"; exit 1; }
TGT=$(readlink -f "$TGT"); mnt=$(findmnt -no TARGET -T "$TGT")
if [ "$mnt" = / ]; then rel="${TGT#/}"; else rel="${TGT#"$mnt"/}"; fi
BK="${BROOT%/}/$rel"
DST="${TGT%.*}.${NEW##*.}"
errs() { journalctl -k --no-pager 2>/dev/null | grep -c 'critical medium error' || true; }
e0=$(errs)
[ -e "$BK" ] && { echo "backup already exists: $BK - aborting"; exit 1; }
[ "$DST" != "$TGT" ] && [ -e "$DST" ] && { echo "destination exists: $DST - aborting"; exit 1; }
mkdir -p "$(dirname "$BK")"
mv -n "$TGT" "$BK" && echo "original moved to: $BK"
cp -n "$NEW" "$DST"
python3 -I -c '
import os, sys
for p in sys.argv[1:]:
    fd = os.open(p, os.O_RDONLY); os.fsync(fd); os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED); os.close(fd)
' "$DST" "$NEW"
if cmp "$DST" "$NEW"; then echo "[OK] read-back from disk identical: $DST ($(stat -c %s "$DST") bytes)"
else echo "[FAIL] read-back differs: $DST - original is still in $BK"; exit 1; fi
e1=$(errs)
if [ "$e1" != "$e0" ]; then echo "[WARN] new kernel medium errors during swap ($e0 -> $e1): check the drive"; else echo "no new kernel disk errors"; fi
