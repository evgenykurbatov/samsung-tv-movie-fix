#!/usr/bin/env python3
"""Dump the RIFF structure of AVI files: avih, every stream's strh + strf (BITMAPINFOHEADER / WAVEFORMATEX),
stream names, OpenDML (dmlh, indx), INFO tags and the top-level layout (movi size, idx1 entries, AVIX parts).
Header-only: seeks over the media data, so it is cheap even on a failing drive.

Usage:  python3 -I avi_headers.py FILE.avi [FILE.avi ...]

Use it to compare a failing AVI with a playing one (docs/recipes.md). Worth noticing:
  - video strf biSize > 40 with extradata, bitcount 24, handler 'XVID' = written by ffmpeg/mencoder (lavf);
    Xvid's own writer: biSize 40, bitcount 12, handler 'xvid';
  - avih flags 0x110 = HASINDEX|ISINTERLEAVED; an idx1 after movi; 'indx' / RIFF AVIX = OpenDML (> 1 GiB parts);
  - audio format tag 0x2000 = AC-3, 0x2001 = DTS (not supported), 0x55 = MP3, 0xFF = AAC.
Exit codes: 0 = all files parsed, 2 = usage error / a file is not an AVI.
"""
import argparse, os, struct, sys

WAVE_TAGS = {0x1: 'PCM', 0x50: 'MPEG audio', 0x55: 'MP3', 0xFF: 'AAC', 0x2000: 'AC-3', 0x2001: 'DTS', 0x161: 'WMA'}
AVIF = {0x10: 'HASINDEX', 0x20: 'MUSTUSEINDEX', 0x100: 'ISINTERLEAVED', 0x800: 'TRUSTCKTYPE', 0x10000: 'WASCAPTUREFILE'}


def s4(b):
    return b.decode('latin1')


def dump(path):
    size = os.path.getsize(path)
    out, st = [], {'type': None, 'n': -1}
    with open(path, 'rb') as f:
        if f.read(12)[8:12] != b'AVI ':
            raise ValueError('not an AVI')

        def walk(pos, end, depth):
            while pos + 8 <= end:
                f.seek(pos); h = f.read(12)
                if len(h) < 8:
                    return
                cid, sz = h[:4], struct.unpack('<I', h[4:8])[0]
                ind = '  ' * depth
                if cid in (b'RIFF', b'LIST'):
                    typ = h[8:12]
                    if typ == b'movi':
                        out.append(f'{ind}LIST movi: {sz:,} bytes of media data')
                    else:
                        out.append(f'{ind}{s4(cid)} {s4(typ)} ({sz:,} bytes)')
                        walk(pos + 12, min(pos + 8 + sz, end), depth + 1)
                else:
                    f.seek(pos + 8); d = f.read(min(sz, 1 << 16))
                    out.append(ind + chunk(cid, sz, d, st))
                pos += 8 + sz + (sz & 1)
        walk(0, size, 0)
    return out


def chunk(cid, sz, d, st):
    if cid == b'avih' and len(d) >= 40:
        us, maxbps, _, fl, tot, init, n, sugg, w, h = struct.unpack('<10I', d[:40])
        names = '|'.join(v for k, v in AVIF.items() if fl & k) or '-'
        return (f'avih: {1e6 / us if us else 0:.3f} fps ({us} us/frame), flags=0x{fl:x} ({names}), frames={tot}, '
                f'initial={init}, streams={n}, suggested_buffer={sugg}, {w}x{h}, max_bytes_per_sec={maxbps}')
    if cid == b'strh' and len(d) >= 48:
        t, hnd = d[:4], d[4:8]
        fl, pri, lang, init, scale, rate, start, length, sugg, q, ss = struct.unpack('<IHHIIIIIIiI', d[8:48])
        st['type'] = t; st['n'] += 1
        return (f'strh #{st["n"]} {s4(t)} handler={hnd!r} rate/scale={rate}/{scale} ({rate / scale if scale else 0:.4f}/s) '
                f'start={start} length={length} init={init} flags={fl} suggested_buffer={sugg} quality={q} samplesize={ss}')
    if cid == b'strf':
        if st['type'] == b'vids' and len(d) >= 40:
            bs, w, h, pl, bc, comp, img = struct.unpack('<IiiHHII', d[:24])
            extra = d[40:bs] if bs > 40 else b''
            return (f'strf BITMAPINFOHEADER: chunk={sz} biSize={bs} {w}x{h} planes={pl} bitcount={bc} '
                    f'compression={struct.pack("<I", comp)!r} sizeimage={img} extradata={len(extra)} bytes'
                    + (f' ({extra[:24].hex()}...)' if extra else ''))
        if st['type'] == b'auds' and len(d) >= 16:
            tag, ch, sr, abps, align, bits = struct.unpack('<HHIIHH', d[:16])
            name = WAVE_TAGS.get(tag, '?')
            if tag == 0xFFFE and len(d) >= 28:  # WAVEFORMATEXTENSIBLE: real format = first 2 bytes of the SubFormat GUID
                sub = struct.unpack('<H', d[24:26])[0]; name = f'EXTENSIBLE: {WAVE_TAGS.get(sub, hex(sub))}'
            return (f'strf WAVEFORMATEX: tag=0x{tag:x} ({name}) channels={ch} rate={sr} '
                    f'avg_bytes_per_sec={abps} ({abps * 8 // 1000} kbps) block_align={align} bits={bits} extra={d[16:].hex() or "-"}')
        return f'strf ({sz} bytes, stream type {st["type"]!r})'
    if cid == b'strn':
        return f'strn: {d.rstrip(bytes(1)).decode("latin1")!r}'
    if cid == b'dmlh' and len(d) >= 4:
        return f'dmlh (OpenDML): total_frames={struct.unpack("<I", d[:4])[0]}'
    if cid == b'indx' and len(d) >= 24:
        lpe, sub, typ, n, ck = struct.unpack('<HBBI4s', d[:12])
        return f'indx (OpenDML index): type={typ} entries={n} chunk={s4(ck)}'
    if cid == b'idx1':
        return f'idx1: {sz // 16:,} entries'
    if cid in (b'JUNK', b'vprp'):
        return f'{s4(cid)} ({sz} bytes)'
    if cid[:1] == b'I' and len(d) < 1024:  # INFO tags: ISFT (software), INAM (title), ...
        return f'{s4(cid)}: {d.rstrip(bytes(1)).decode("latin1")!r}'
    return f'{s4(cid)} ({sz:,} bytes)'


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('files', nargs='+')
    a = ap.parse_args()
    rc = 0
    for p in a.files:
        print(f'== {p}')
        try:
            for line in dump(p):
                print('  ' + line)
        except (OSError, ValueError, struct.error) as e:
            print(f'  cannot parse: {e}'); rc = 2
    sys.exit(rc)


if __name__ == '__main__':
    main()
