#!/usr/bin/env python3
"""Normalize the video BITMAPINFOHEADER of an MPEG-4 (Xvid/DivX) AVI IN PLACE - header bytes only.

Usage:  python3 -I avi_fix_bih.py COPY.avi [--dry-run]       (work on a COPY, never on the only original)

AVIs written by ffmpeg/mencoder (lavf) store the MPEG-4 VOS/VOL header as "extradata" behind the
BITMAPINFOHEADER (biSize = 40 + extradata, biBitCount = 24, handler 'XVID'). Xvid's own VfW writer stores a plain
40-byte header (biBitCount 12, biSizeImage = w*h*6, handler 'xvid'). mkvmerge's default (VFW) mode copies the
header verbatim into the MKV CodecPrivate.
What it does: strf shrinks to 40 bytes and the freed bytes become a JUNK chunk of the same total size;
biSize = 40, biBitCount = 12, biSizeImage = w*h*6, strh fccHandler = lowercase FourCC. No byte outside the header
changes: prove it with `cmp -l ORIG COPY`. Refuses unless the first video frame carries the VOL header in-band.
Evidence (docs/case-log.md, Sherlock S1): this patch alone did NOT make a refused file play; a native-mode MKV
(--engage native_mpeg4) did, and native mode ignores this header anyway. Use it when the file must stay an AVI.
Exit codes: 0 = patched (or nothing to do), 1 = refused (unsafe to patch), 2 = usage error / not an AVI.
"""
import argparse, os, struct, sys


def chunks(b, pos, end):
    while pos + 8 <= end:
        cid = bytes(b[pos:pos + 4]); sz = struct.unpack_from('<I', b, pos + 4)[0]
        yield pos, cid, sz
        pos += 8 + sz + (sz & 1)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('file'); ap.add_argument('--dry-run', action='store_true')
    a = ap.parse_args()
    try:
        with open(a.file, 'rb') as f:
            b = bytearray(f.read(1 << 16))
    except OSError as e:
        print(e, file=sys.stderr); sys.exit(2)
    if b[:4] != b'RIFF' or b[8:12] != b'AVI ':
        print('not an AVI', file=sys.stderr); sys.exit(2)
    strh = strf = None
    for p, cid, sz in chunks(b, 12, len(b)):
        if cid == b'LIST' and b[p + 8:p + 12] == b'hdrl':
            for q, c2, s2 in chunks(b, p + 12, p + 8 + sz):
                if c2 == b'LIST' and b[q + 8:q + 12] == b'strl':
                    kids = {c3: (r, s3) for r, c3, s3 in chunks(b, q + 12, q + 8 + s2)}
                    if b'strh' in kids and b[kids[b'strh'][0] + 8:kids[b'strh'][0] + 12] == b'vids':
                        strh, strf = kids[b'strh'], kids.get(b'strf'); break
            break
    if not (strh and strf):
        print('[FAIL] no video stream header found'); sys.exit(1)
    fp, fsz = strf
    bisize, w, h, planes, bits, comp, img = struct.unpack_from('<IiiHHII', b, fp + 8)
    fourcc = struct.pack('<I', comp)
    print(f'before: strf size={fsz} biSize={bisize} {w}x{h} bitcount={bits} sizeimage={img} comp={fourcc!r} '
          f'handler={bytes(b[strh[0] + 12:strh[0] + 16])!r}')
    if fsz <= 40 and bisize == 40:
        print('[OK] already a plain 40-byte BITMAPINFOHEADER - nothing to do'); sys.exit(0)
    extra = bytes(b[fp + 8 + 40:fp + 8 + fsz])
    if extra[:3] != b'\x00\x00\x01':
        print('[FAIL] extradata is not an MPEG-4 header - refusing'); sys.exit(1)
    mv = b.find(b'movi'); vf = b.find(b'00dc', mv) if mv > 0 else -1     # first video frame chunk
    head = bytes(b[vf + 8:vf + 8 + 64]) if vf > 0 else b''
    if not any(head.find(b'\x00\x00\x01' + bytes([c])) >= 0 for c in range(0x20, 0x30)):
        print('[FAIL] first video frame has no in-band VOL header - removing the extradata would break decoding'); sys.exit(1)
    total = 8 + fsz + (fsz & 1); junk = total - 48 - 8
    if junk < 0:
        print('[FAIL] not enough room for a JUNK chunk'); sys.exit(1)
    new = bytearray(struct.pack('<4sI', b'strf', 40)) + b[fp + 8:fp + 48]
    struct.pack_into('<IiiHHII', new, 8, 40, w, h, planes, 12, comp, abs(w * h) * 6)
    new += struct.pack('<4sI', b'JUNK', junk) + bytes(junk)
    assert len(new) == total
    print(f'after:  strf size=40 biSize=40 bitcount=12 sizeimage={abs(w * h) * 6} handler={fourcc.lower()!r} + JUNK {junk} bytes '
          f'(removed extradata: {extra.hex()})')
    if a.dry_run:
        print('dry run - file not changed'); sys.exit(0)
    with open(a.file, 'r+b') as f:
        f.seek(fp); f.write(new)
        f.seek(strh[0] + 12); f.write(fourcc.lower())
        f.flush(); os.fsync(f.fileno())
    print(f'[OK] patched {a.file}')


if __name__ == '__main__':
    main()
