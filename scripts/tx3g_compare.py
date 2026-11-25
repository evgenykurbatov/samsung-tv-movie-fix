#!/usr/bin/env python3
"""Prove that an SRT converted from MP4 timed text (tx3g / mov_text) keeps every cue: start, end and text.

Usage:  python3 -I tx3g_compare.py FILE.m4v SUB_INDEX CONVERTED.srt

SUB_INDEX      ffmpeg subtitle index (0 = first subtitle stream, as in -map 0:s:0).
CONVERTED.srt  made with `ffmpeg -i FILE.m4v -map 0:s:N -c:s srt x.srt`, then with the <font size="NN"> tags that
               ffmpeg adds removed: sed -E 's#<font size="[0-9]+">##g; s#</font>##g'. Keep <i> (italics).
Compares the raw tx3g samples (2-byte length + UTF-8 text, then optional style boxes) with the SRT cues after
removing <i></i>. The number of cues with <i> should equal the number of samples with style boxes.
Exit codes: 0 = identical, 1 = differences, 2 = usage error or missing tool.
"""
import argparse, json, re, shutil, subprocess, sys

TS = re.compile(r'(\d+):(\d\d):(\d\d)[,.](\d{1,3})\s*-->\s*(\d+):(\d\d):(\d\d)[,.](\d{1,3})')


def ms(h, m, s, f):
    return ((int(h) * 60 + int(m)) * 60 + int(s)) * 1000 + int(f.ljust(3, '0'))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('source'); ap.add_argument('sub_index'); ap.add_argument('srt')
    a = ap.parse_args()
    if not shutil.which('ffprobe'):
        print('missing tool: ffprobe (run scripts/check_deps.sh)', file=sys.stderr); sys.exit(2)
    r = subprocess.run(['ffprobe', '-v', 'error', '-select_streams', 's:' + a.sub_index, '-show_packets', '-show_data',
                        '-show_entries', 'stream=time_base:packet=pts,duration,data', '-of', 'json', a.source],
                       capture_output=True, text=True)
    j = json.loads(r.stdout or '{}')
    if not j.get('streams'):
        print(f'no subtitle stream s:{a.sub_index} in {a.source}', file=sys.stderr); sys.exit(2)
    num, den = map(int, j['streams'][0]['time_base'].split('/'))
    raw, styled = [], 0
    for p in j.get('packets', []):
        hexs = ''.join(re.findall(r'^[0-9a-f]{8}: ((?:[0-9a-f]{2,4} ?)+)', p.get('data', ''), re.M)).replace(' ', '')
        b = bytes.fromhex(hexs)
        if len(b) < 2:
            continue
        n = int.from_bytes(b[:2], 'big'); t = b[2:2 + n].decode('utf-8', errors='replace')
        if len(b) > 2 + n:
            styled += 1
        if t.strip():
            s = round(p['pts'] * num * 1000 / den); e = round((p['pts'] + p['duration']) * num * 1000 / den)
            raw.append((s, e, t.replace('\r', '').strip()))
    text = open(a.srt, encoding='utf-8-sig').read().replace('\r\n', '\n').replace('\r', '\n')
    cues, ital, font = [], 0, 0
    for blk in re.split(r'\n\s*\n', text.strip()):
        lines = blk.split('\n')
        for i, line in enumerate(lines):
            m = TS.search(line)
            if m:
                txt = '\n'.join(lines[i + 1:]).strip()
                ital += '<i>' in txt; font += '<font' in txt
                g = m.groups(); cues.append((ms(*g[:4]), ms(*g[4:]), re.sub(r'</?i>', '', txt).strip()))
                break
    print(f'tx3g s:{a.sub_index}: {len(raw)} text samples ({styled} with style boxes), srt: {len(cues)} cues ({ital} with <i>)')
    if font:
        print(f'[FAIL] {font} cues still contain <font> tags - strip them first (see --help)'); sys.exit(1)
    bad = [(i, x, y) for i, (x, y) in enumerate(zip(raw, cues)) if x != y]
    if len(raw) == len(cues) and not bad:
        print('[OK] every cue identical (start ms, end ms, text without the <i> tags)'
              + ('' if ital == styled else f' [NOTE] italics count {ital} != styled samples {styled}: check styles'))
        sys.exit(0)
    print(f'[FAIL] {len(bad)} cues differ (counts: tx3g {len(raw)}, srt {len(cues)}); first: {bad[:3]}')
    sys.exit(1)


if __name__ == '__main__':
    main()
