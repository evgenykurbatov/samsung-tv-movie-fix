#!/usr/bin/env python3
"""Read every packet of a media file (no decoding) and report per-stream counts, timestamp sanity,
the peak 1-second video bitrate, the longest GOP and tiny video packets (Xvid/DivX drop frames).
It doubles as a cheap full-file read test: demuxer/read errors are printed.

Usage:  python3 -I packet_scan.py FILE [--keep-csv OUT.csv]

--keep-csv  save the packet table (stream,pts,dts,size,flags). Keep it: if the source later becomes
            unreadable (failing drive), a remux can still be compared with it packet by packet.
Tiny video packets (0-7 bytes) in Xvid/DivX AVIs are not-coded "drop" frames: each holds the previous picture
for one frame slot. mkvmerge --engage native_mpeg4 discards them AND closes their time slot (A/V drift), so a
native remux of such a file needs a timestamp file: see ts_v2_from_frames.py.
Exit codes: 0 = read without errors, 1 = demuxer/read errors (check the drive), 2 = usage error or missing tool.
"""
import argparse, collections, csv, io, shutil, subprocess, sys


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('file')
    ap.add_argument('--keep-csv', metavar='OUT.csv')
    a = ap.parse_args()
    if not shutil.which('ffprobe'):
        print('missing tool: ffprobe (run scripts/check_deps.sh)', file=sys.stderr); sys.exit(2)
    v = subprocess.run(['ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=index',
                        '-of', 'csv=p=0', a.file], capture_output=True, text=True)
    if v.returncode:
        print(v.stderr.strip() or f'cannot read {a.file}', file=sys.stderr); sys.exit(2)
    vid = v.stdout.strip().split('\n')[0] if v.stdout.strip() else None
    p = subprocess.run(['ffprobe', '-v', 'error', '-show_entries', 'packet=stream_index,pts_time,dts_time,size,flags',
                        '-of', 'csv=p=0', a.file], capture_output=True, text=True)
    if a.keep_csv:
        with open(a.keep_csv, 'w') as fh:
            fh.write(p.stdout)
    st = collections.defaultdict(lambda: dict(n=0, bytes=0, maxsize=0, dts_back=0, first=None, last=None, _prev=None))
    win, kf, tiny = collections.defaultdict(int), [], []
    for row in csv.reader(io.StringIO(p.stdout)):
        if len(row) < 5:
            continue
        si, pts, dts, size, flags = row[:5]
        s = st[si]; sz = int(size); s['n'] += 1; s['bytes'] += sz; s['maxsize'] = max(s['maxsize'], sz)
        t = dts if dts not in ('N/A', '') else pts
        if si == vid and sz <= 7:
            tiny.append(t)
        if t in ('N/A', ''):
            continue
        t = float(t)
        if s['first'] is None:
            s['first'] = t
        s['last'] = t
        if s['_prev'] is not None and t < s['_prev']:
            s['dts_back'] += 1
        s['_prev'] = t
        if si == vid:
            win[int(t)] += sz
            if 'K' in flags:
                kf.append(t)
    print(f'== {a.file}')
    for k, s in sorted(st.items(), key=lambda x: int(x[0])):
        s.pop('_prev'); print(f'stream {k}{" (video)" if k == vid else ""}: {s}')
    if win:
        top = sorted(win.items(), key=lambda x: x[1])[-5:]
        print(f'stream {vid} peak 1s bitrate (Mbps @ second):', [(round(b * 8 / 1e6, 1), t) for t, b in reversed(top)])
    if len(kf) > 1:
        print(f'keyframes: {len(kf)}, longest GOP {max(y - x for x, y in zip(kf, kf[1:])):.2f}s')
    if tiny:
        # (8+ byte packets can be real all-skipped B-frames.) Confirm: decoded frame count < packet count.
        print(f'stream {vid} tiny packets (<= 7 bytes, likely drop frames): {len(tiny)} at {tiny[:8]}'
              f'{" ..." if len(tiny) > 8 else ""} -> native_mpeg4 remux needs a timestamp file (ts_v2_from_frames.py)')
    else:
        print('tiny video packets (drop frames): none')
    err = p.stderr.strip()
    print('read/demux errors:', err or 'none')
    sys.exit(1 if err else 0)


if __name__ == '__main__':
    main()
