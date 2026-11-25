#!/usr/bin/env python3
"""Decode the MPEG-4 Part 2 (DivX/Xvid) stream headers: VOS profile/level, VO, VOL fields, user data strings,
and how often VOS/VOL headers repeat in-band. Scans the start of the file for start codes, so it works on AVI,
native-mode MKV and MP4 alike.

Usage:  python3 -I mpeg4_vol.py FILE [FILE ...] [--scan-mb 8]

Check against the TV (Samsung 2026: MPEG-4 SP/ASP; "GMC 2 and higher: Not supported"):
  profile_and_level 0xF0-0xF5 = Advanced Simple L0-L5; sprite_enable + warping points (GMC);
  quarter_sample (qpel); interlaced; quant_type (H.263, or MPEG with custom matrices); low_delay 0 = B-frames.
User data like "DivX503b1393p" (trailing p) means a packed bitstream; "XviD0064" is the Xvid build.
Exit codes: 0 = parsed, 1 = GMC/sprite with >= 2 warping points (unsupported), 2 = usage error / no VOL found.
"""
import argparse, re, sys

PROFILES = {0x08: 'Simple L0', 0x01: 'Simple L1', 0x02: 'Simple L2', 0x03: 'Simple L3', 0x04: 'Simple L4a',
            0x05: 'Simple L5', 0xF0: 'Advanced Simple L0', 0xF1: 'Advanced Simple L1', 0xF2: 'Advanced Simple L2',
            0xF3: 'Advanced Simple L3', 0xF4: 'Advanced Simple L4', 0xF5: 'Advanced Simple L5', 0xF7: 'Advanced Simple L3b'}


class Bits:
    def __init__(s, b): s.b, s.p = b, 0
    def u(s, n):
        v = 0
        for _ in range(n):
            v = (v << 1) | ((s.b[s.p >> 3] >> (7 - (s.p & 7))) & 1); s.p += 1
        return v


def parse_vol(buf):
    b, o = Bits(buf), {}
    o['random_accessible_vol'] = b.u(1); o['vo_type_indication'] = b.u(8)
    ver = 1
    if b.u(1):
        ver = b.u(4); b.u(3)
    o['verid'] = ver
    ar = b.u(4); o['aspect_ratio_info'] = ar
    if ar == 15:
        o['par'] = f'{b.u(8)}:{b.u(8)}'
    if b.u(1):
        o['chroma_format'] = b.u(2); o['low_delay'] = b.u(1)
        if b.u(1):
            br = b.u(15) << 15; b.u(1); br |= b.u(15); b.u(1); vb = b.u(15) << 3; b.u(1); vb |= b.u(3)
            b.u(11); b.u(1); b.u(15); b.u(1)
            o['vbv_bitrate_bps'] = br * 400; o['vbv_buffer_bits'] = vb * 16384
    shape = b.u(2); o['shape'] = shape
    if shape != 0:
        o['note'] = 'non-rectangular shape: parsing stopped'; return o
    b.u(1); res = b.u(16); o['time_increment_resolution'] = res; b.u(1)
    if b.u(1):
        o['fixed_vop_time_increment'] = b.u(max(1, (res - 1).bit_length()))
    b.u(1); w = b.u(13); b.u(1); h = b.u(13); b.u(1); o['size'] = f'{w}x{h}'
    o['interlaced'] = b.u(1); o['obmc_disable'] = b.u(1)
    sp = b.u(1 if ver == 1 else 2); o['sprite_enable'] = {0: 'none', 1: 'static', 2: 'GMC'}.get(sp, sp)
    if sp in (1, 2):
        if sp != 2:
            for _ in range(4):
                b.u(13); b.u(1)
        o['sprite_warping_points'] = b.u(6); o['sprite_warping_accuracy'] = b.u(2); b.u(1)
        if sp != 2:
            b.u(1)
    o['not_8_bit'] = b.u(1)
    if o['not_8_bit']:
        o['quant_precision'] = b.u(4); o['bits_per_pixel'] = b.u(4)
    q = b.u(1); o['quant_type'] = 'MPEG' if q else 'H.263'
    if q:
        for nm in ('intra', 'nonintra'):
            if b.u(1):
                n = 0
                while n < 64:
                    n += 1
                    if b.u(8) == 0:
                        break
                o[f'custom_{nm}_matrix'] = f'yes ({n} values)'
            else:
                o[f'custom_{nm}_matrix'] = 'no'
    if ver != 1:
        o['quarter_sample'] = b.u(1)
    o['complexity_estimation_disable'] = b.u(1)
    if not o['complexity_estimation_disable']:
        o['note'] = 'complexity estimation header present: parsing stopped'; return o
    o['resync_marker_disable'] = b.u(1); dp = b.u(1); o['data_partitioned'] = dp
    if dp:
        o['reversible_vlc'] = b.u(1)
    if ver != 1:
        o['newpred_enable'] = b.u(1)
        if o['newpred_enable']:
            b.u(2); b.u(1)
        o['reduced_resolution_vop_enable'] = b.u(1)
    o['scalability'] = b.u(1)
    return o


def report(path, scan):
    with open(path, 'rb') as f:
        data = f.read(scan)
    print(f'== {path}')
    k = data.find(b'\x00\x00\x01\xb0')
    if k >= 0:
        pl = data[k + 4]
        print(f'  VOS profile_and_level: 0x{pl:02x} ({PROFILES.get(pl, "?")})')
    k = data.find(b'\x00\x00\x01\xb5')
    if k >= 0:
        b = Bits(data[k + 4:k + 20])
        if b.u(1):
            b.u(4); b.u(3)
        t = b.u(4); vs = b.u(1)
        s = f'  VO: type={t} video_signal_type={vs}'
        if vs:
            s += f' format={b.u(3)} full_range={b.u(1)}'
            if b.u(1):
                s += f' colour={b.u(8)},{b.u(8)},{b.u(8)}'
        print(s)
    m = re.search(rb'\x00\x00\x01[\x20-\x2f]', data)
    if not m:
        print('  no VOL header found in the scanned range'); return 2
    try:
        o = parse_vol(data[m.end():m.end() + 512])
    except IndexError:
        print('  VOL header truncated'); return 2
    for kk, v in o.items():
        print(f'  {kk}: {v}')
    vos = len(re.findall(rb'\x00\x00\x01\xb0', data)); vol = len(re.findall(rb'\x00\x00\x01[\x20-\x2f]', data))
    print(f'  in the first {len(data) >> 20} MiB: {vos} VOS and {vol} VOL headers (repeated = in-band at keyframes)')
    ud = {}
    for u in re.findall(rb'\x00\x00\x01\xb2([\x20-\x7e]{3,})', data):
        ud[u] = ud.get(u, 0) + 1
    for u, n in ud.items():
        print(f'  user data: {u.decode()!r} x{n}' + ('  (packed bitstream)' if re.match(rb'DivX\d+.*p$', u) else ''))
    if o.get('sprite_warping_points', 0) >= 2:
        print('  RED FLAG: GMC/sprite with >= 2 warping points is not supported by the TV -> re-encode needed, ASK USER')
        return 1
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('files', nargs='+'); ap.add_argument('--scan-mb', type=int, default=8)
    a = ap.parse_args()
    rc = 0
    for p in a.files:
        try:
            rc = max(rc, report(p, a.scan_mb << 20))
        except OSError as e:
            print(f'  {e}'); rc = 2
    sys.exit(rc)


if __name__ == '__main__':
    main()
