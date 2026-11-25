#!/usr/bin/env python3
"""Prove that a subtitle track muxed into an MKV carries exactly the cues of the source .srt file.

Usage:  python3 -I srt_compare.py SOURCE.srt FILE.mkv TRACK_ID [--charset cp1251]

TRACK_ID   mkvmerge track ID of the muxed subtitle track (see `mkvmerge -J` / inspect.sh).
--charset  encoding of SOURCE.srt (default: utf-8, BOM allowed). Detect it first, e.g. `file -i x.srt`;
           "iso-8859-1"/"unknown-8bit" for Russian text is nearly always cp1251 - check with
           `iconv -f cp1251 -t utf-8 x.srt | head`.
Both sides are parsed into (start_ms, end_ms, text) cues; line endings, BOM, cue numbering and trailing
whitespace are normalized (mkvmerge rewrites all of those). Fails if the extracted text contains U+FFFD
(a wrong --sub-charset at mux time). Also prints the track's language/default/forced flags.
Exit codes: 0 = identical, 1 = differences, 2 = usage error, missing tool or undecodable source.
"""
import argparse, json, os, re, shutil, subprocess, sys, tempfile

TS = re.compile(r'(\d+):(\d\d):(\d\d)[,.](\d{1,3})\s*-->\s*(\d+):(\d\d):(\d\d)[,.](\d{1,3})')


def ms(h, m, s, f):
    return ((int(h) * 60 + int(m)) * 60 + int(s)) * 1000 + int(f.ljust(3, '0'))


def parse(text):
    text = text.lstrip('﻿').replace('\r\n', '\n').replace('\r', '\n')
    cues = []
    for block in re.split(r'\n\s*\n', text.strip()):
        lines = block.split('\n')
        for i, line in enumerate(lines):
            m = TS.search(line)
            if m:
                g = m.groups()
                body = '\n'.join(x.rstrip() for x in lines[i + 1:]).strip('\n')
                cues.append((ms(*g[:4]), ms(*g[4:]), body))
                break
    return cues


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('source'); ap.add_argument('mkv'); ap.add_argument('track_id', type=int)
    ap.add_argument('--charset', default='utf-8-sig')
    a = ap.parse_args()
    missing = [t for t in ('mkvmerge', 'mkvextract') if not shutil.which(t)]
    if missing:
        print(f'missing tool: {" ".join(missing)} (run scripts/check_deps.sh)', file=sys.stderr); sys.exit(2)
    try:
        old = parse(open(a.source, encoding=a.charset).read())
    except (UnicodeDecodeError, LookupError) as e:
        print(f'cannot decode {a.source} as {a.charset}: {e} -> pass the right --charset', file=sys.stderr); sys.exit(2)
    info = json.loads(subprocess.run(['mkvmerge', '-J', a.mkv], capture_output=True, text=True, check=True).stdout)
    tr = next((t for t in info['tracks'] if t['id'] == a.track_id), None)
    if not tr or tr['type'] != 'subtitles':
        print(f'track {a.track_id} is not a subtitle track in {a.mkv}', file=sys.stderr); sys.exit(2)
    p = tr['properties']
    print(f"track {a.track_id}: {tr['codec']} lang={p.get('language')} name={p.get('track_name', '-')} "
          f"default={p.get('default_track')} forced={p.get('forced_track')}")
    with tempfile.TemporaryDirectory() as d:
        out = os.path.join(d, 't.srt')
        subprocess.run(['mkvextract', a.mkv, 'tracks', f'{a.track_id}:{out}'], capture_output=True, check=True)
        new_text = open(out, encoding='utf-8', errors='replace').read()
    new = parse(new_text)
    bad = 0
    if '�' in new_text:
        print('[FAIL] extracted track contains U+FFFD replacement characters (wrong charset at mux time?)'); bad = 1
    if len(old) != len(new):
        print(f'[FAIL] cue count differs: source {len(old)}, mkv {len(new)}'); bad = 1
    # mkvmerge sorts cues by start time; compare in that order
    so, sn = sorted(old, key=lambda c: c[0]), sorted(new, key=lambda c: c[0])
    diffs = [(i, o, n) for i, (o, n) in enumerate(zip(so, sn)) if o != n]
    for i, o, n in diffs[:5]:
        print(f'[FAIL] cue {i + 1}: source {o!r}\n                 mkv    {n!r}')
    if diffs:
        print(f'[FAIL] {len(diffs)} differing cues'); bad = 1
    if not bad:
        first = next((c[2] for c in so if c[2]), '')
        print(f'[OK] {len(new)} cues identical (timing + text); first text: {first.splitlines()[0][:60] if first else ""!r}')
    sys.exit(bad)


if __name__ == '__main__':
    main()
