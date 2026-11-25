#!/usr/bin/env python3
"""Write an mkvmerge v2 timestamp file that gives every frame of a native-mode MPEG-4 remux the presentation time it
had in the original AVI. Needed when the AVI has Xvid/DivX "drop" frames (packet_scan.py lists them):
--engage native_mpeg4 discards them and closes their time slot, so without this file the video runs ahead of the
audio after the first drop frame.

Usage:  python3 -I ts_v2_from_frames.py ORIG.avi [--shift-ms N] [--from-verify WORKDIR/v_orig] > ts.txt

ORIG is decoded once with ffmpeg; --from-verify reuses the "seconds,md5" list verify_remux.sh saved instead.
--shift-ms  subtracted from every timestamp. Default: one frame duration (rounded to ms) when ORIG has B-frames,
            else 0. Reason: AVI has no PTS, so a B-frame stream decodes one frame late; native mode removes that
            delay (40 ms at 25 fps, 42 ms at 23.976/24 fps) - the same offset a drop-frame-free native remux gets.
Then:   mkvmerge -o out.mkv --engage native_mpeg4 --timestamps 0:ts.txt [other options] ORIG.avi [subtitles...]
        verify_remux.sh ORIG.avi out.mkv  -> must report "[NOTE] constant frame-timestamp offset".
Statistics go to stderr: frames, frame duration, gaps (expect one per drop frame).
Exit codes: 0 = written, 2 = usage error, missing tool or no frames decoded.
"""
import argparse, shutil, statistics, subprocess, sys


def decode_times(path):
    p = subprocess.run(['ffmpeg', '-nostdin', '-v', 'error', '-i', path, '-map', '0:v:0', '-vsync', 'passthrough',
                        '-f', 'framemd5', '-'], capture_output=True, text=True)
    tb, out = None, []
    for line in p.stdout.splitlines():
        if line.startswith('#tb 0:'):
            n, d = line.split(':', 1)[1].strip().split('/'); tb = int(n) / int(d)
        elif line and line[0] != '#' and tb:
            out.append(int(line.split(',')[2]) * tb)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('orig'); ap.add_argument('--shift-ms', type=int); ap.add_argument('--from-verify', metavar='V_ORIG')
    a = ap.parse_args()
    missing = [t for t in ('ffmpeg', 'ffprobe') if not shutil.which(t)]
    if missing:
        print(f'missing tool: {" ".join(missing)} (run scripts/check_deps.sh)', file=sys.stderr); sys.exit(2)
    if a.from_verify:
        times = [float(line.split(',')[0]) for line in open(a.from_verify) if line.strip()]
    else:
        times = decode_times(a.orig)
    if len(times) < 2:
        print(f'no frames decoded from {a.orig}', file=sys.stderr); sys.exit(2)
    times.sort()
    dur = statistics.median(y - x for x, y in zip(times, times[1:]))
    shift = a.shift_ms
    if shift is None:
        hb = subprocess.run(['ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=has_b_frames',
                             '-of', 'csv=p=0', a.orig], capture_output=True, text=True).stdout.strip()
        shift = round(dur * 1000) if hb not in ('', '0') else 0
    ms = [int(t * 1000 + 0.5) - shift for t in times]
    if ms[0] < 0:
        print(f'first timestamp would be negative ({ms[0]} ms): use a smaller --shift-ms', file=sys.stderr); sys.exit(2)
    gaps = [(times[i], round((y - x) * 1000)) for i, (x, y) in enumerate(zip(times, times[1:]), 1) if y - x > dur * 1.5]
    print('# timestamp format v2')
    print('\n'.join(map(str, ms)))
    print(f'{len(ms)} frames, frame duration {dur * 1000:.3f} ms, shift {shift} ms, gaps > 1.5 frames: {len(gaps)}'
          + (f' at {[f"{t:.2f}s (+{g} ms)" for t, g in gaps[:8]]}' if gaps else ''), file=sys.stderr)


if __name__ == '__main__':
    main()
