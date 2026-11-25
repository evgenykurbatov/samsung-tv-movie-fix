#!/usr/bin/env python3
"""Report every H.264 SPS of a file: the one in the container header (MKV CodecPrivate / MP4 avcC)
AND every in-band SPS, with timestamps.

Usage:  python3 -I h264_sps_report.py FILE [VIDEO_INDEX=0]

Why: the TV may reject a stream whose SPS says something odd (e.g. VUI timing claiming 90000 fps VFR), and
spliced/edited streams can carry several different SPS mid-stream - looking only at the header misses them.
Look at: VUI_FPS (time_scale / 2*num_units_in_tick) and fixed_frame_rate; profile_idc (100 = High OK,
110 = High10 not supported); level_idc (FHD <= 42); bit depth 8; frame_mbs_only 0 = interlaced;
max_num_ref_frames vs the level's DPB; several distinct SPS = spliced stream.
Reads the whole video stream once (I/O-bound).
Exit codes: 0 = nothing alarming, 1 = VUI frame rate absurd (> 120 or < 1 fps) or bit depth > 8,
            2 = usage error or missing tool.
"""
import argparse, collections, json, os, re, shutil, subprocess, sys, tempfile


def rbsp(b):
    out, zeros = bytearray(), 0
    for x in b:
        if zeros >= 2 and x == 3:
            zeros = 0
            continue
        out.append(x)
        zeros = zeros + 1 if x == 0 else 0
    return bytes(out)


class Bits:
    def __init__(s, b): s.b, s.p = b, 0
    def u(s, n):
        v = 0
        for _ in range(n):
            v = (v << 1) | ((s.b[s.p >> 3] >> (7 - (s.p & 7))) & 1); s.p += 1
        return v
    def ue(s):
        z = 0
        while s.u(1) == 0: z += 1
        return (1 << z) - 1 + s.u(z)
    def se(s):
        k = s.ue(); return (k + 1) // 2 if k & 1 else -(k // 2)


def parse_sps(nal):
    """nal = SPS NAL unit bytes including the 1-byte NAL header."""
    r, d = Bits(rbsp(nal)[1:]), {}
    try:
        d['profile_idc'] = r.u(8); d['constraint_flags'] = r.u(8); d['level_idc'] = r.u(8); d['sps_id'] = r.ue()
        if d['profile_idc'] in (100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135):
            d['chroma_format_idc'] = r.ue()
            if d['chroma_format_idc'] == 3: r.u(1)
            d['bit_depth_luma'] = r.ue() + 8; d['bit_depth_chroma'] = r.ue() + 8; r.u(1)
            if r.u(1):
                d['scaling_matrix'] = 1
                return d  # rarely used; stop here (fields below would need scaling-list parsing)
        d['log2_max_frame_num'] = r.ue() + 4; d['poc_type'] = r.ue()
        if d['poc_type'] == 0: d['log2_max_poc_lsb'] = r.ue() + 4
        elif d['poc_type'] == 1:
            r.u(1); r.se(); r.se()
            for _ in range(r.ue()): r.se()
        d['max_num_ref_frames'] = r.ue(); d['gaps_allowed'] = r.u(1)
        d['width_mbs'] = r.ue() + 1; d['height_map_units'] = r.ue() + 1
        d['frame_mbs_only'] = r.u(1)
        if not d['frame_mbs_only']: d['mb_adaptive_ff'] = r.u(1)   # interlaced-capable stream
        r.u(1)
        if r.u(1): d['crop_lrtb'] = (r.ue(), r.ue(), r.ue(), r.ue())
        if r.u(1):  # VUI
            if r.u(1):
                d['aspect_ratio_idc'] = r.u(8)
                if d['aspect_ratio_idc'] == 255: d['sar'] = (r.u(16), r.u(16))
            if r.u(1): r.u(1)
            if r.u(1):
                r.u(3); d['full_range'] = r.u(1)
                if r.u(1): d['colour_prim_trc_mat'] = (r.u(8), r.u(8), r.u(8))
            if r.u(1): r.ue(); r.ue()
            if r.u(1):
                d['num_units_in_tick'] = r.u(32); d['time_scale'] = r.u(32); d['fixed_frame_rate'] = r.u(1)
                if d['num_units_in_tick']:
                    d['VUI_FPS'] = round(d['time_scale'] / (2 * d['num_units_in_tick']), 3)
            nal_hrd = r.u(1)
            if nal_hrd:
                cnt = r.ue() + 1; r.u(4); r.u(4)
                for _ in range(cnt): r.ue(); r.ue(); r.u(1)
                r.u(5); r.u(5); r.u(5); r.u(5)
            vcl_hrd = r.u(1)
            d['hrd'] = (nal_hrd, vcl_hrd)
            if vcl_hrd: return d
            if nal_hrd: r.u(1)
            d['pic_struct_present'] = r.u(1)
            if r.u(1):
                r.u(1); r.ue(); r.ue(); r.ue(); r.ue()
                d['max_num_reorder_frames'] = r.ue(); d['max_dec_frame_buffering'] = r.ue()
    except IndexError:
        d['truncated'] = True
    return d


def split_annexb(data):
    return [p.strip(b'\x00') for p in data.split(b'\x00\x00\x01') if p.strip(b'\x00')]


def avcc_sps(cp):
    if len(cp) < 8 or cp[0] != 1:
        return []  # not avcC
    n, pos, out = cp[5] & 0x1F, 6, []
    for _ in range(n):
        ln = int.from_bytes(cp[pos:pos + 2], 'big'); out.append(cp[pos + 2:pos + 2 + ln]); pos += 2 + ln
    return out


def header_sps(path, vidx):
    """SPS from the container header: mkvmerge's codec_private_data (MKV), else ffprobe's extradata (MP4/M4V/MOV)."""
    try:
        j = json.loads(subprocess.run(['mkvmerge', '-J', path], capture_output=True, text=True).stdout)
        v = [t for t in j['tracks'] if t['type'] == 'video'][int(vidx)]
        cp = bytes.fromhex(v['properties'].get('codec_private_data', ''))
        if avcc_sps(cp):
            return avcc_sps(cp)
    except Exception:
        pass
    out = subprocess.run(['ffprobe', '-v', 'error', '-select_streams', f'v:{vidx}', '-show_streams', '-show_data',
                          path], capture_output=True, text=True).stdout
    m = re.search(r'extradata=\n((?:[0-9a-f]{8}: .*\n)+)', out)
    if not m:
        return []
    hexs = ''.join(re.findall(r'^[0-9a-f]{8}: ((?:[0-9a-f]{2,4} ?)+)', m.group(1), re.M)).replace(' ', '')
    return avcc_sps(bytes.fromhex(hexs))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('file')
    ap.add_argument('video_index', nargs='?', default='0', help='ffmpeg video stream index (default 0)')
    a = ap.parse_args()
    missing = [t for t in ('ffmpeg', 'ffprobe', 'mkvmerge') if not shutil.which(t)]
    if missing:
        print(f'missing tool: {" ".join(missing)} (run scripts/check_deps.sh)', file=sys.stderr); sys.exit(2)
    if not os.path.isfile(a.file):
        print(f'not found: {a.file}', file=sys.stderr); sys.exit(2)
    hdr = header_sps(a.file, a.video_index)
    with tempfile.TemporaryDirectory() as td:
        raw, md5 = os.path.join(td, 'sps.h264'), os.path.join(td, 'sps.md5')
        # one read of the file: keep only SPS NALs (type 7), write raw + per-packet timestamps
        subprocess.run(['ffmpeg', '-nostdin', '-v', 'error', '-i', a.file, '-map', f'0:v:{a.video_index}', '-c', 'copy',
                        '-bsf:v', 'filter_units=pass_types=7', '-f', 'tee',
                        f'[f=h264]{raw}|[f=framemd5]{md5}'], check=False)
        sps = split_annexb(open(raw, 'rb').read()) if os.path.exists(raw) else []
        ts, tb = [], 0.001
        if os.path.exists(md5):
            for line in open(md5):
                if line.startswith('#tb 0:'):  # framemd5 time base, e.g. "#tb 0: 1001/24000"
                    n, d = line.split(':', 1)[1].strip().split('/'); tb = int(n) / int(d)
                elif line[0] != '#':
                    ts.append(int(line.split(',')[2]) * tb)  # column 3 = pts
    print(f'== {a.file}')
    for i, s in enumerate(hdr):
        print(f'header SPS #{i}: {parse_sps(s)}')
    if not hdr:
        print('header SPS: none found (not H.264, or Annex B stream without a header)')
    groups = collections.OrderedDict()
    for i, s in enumerate(sps):
        groups.setdefault(s, []).append(ts[i] if len(ts) == len(sps) else None)
    print(f'in-band SPS: {len(sps)} total, {len(groups)} distinct'
          + ('' if len(ts) == len(sps) else '  (packet/SPS count mismatch - timestamps omitted)'))
    for s, times in groups.items():
        same = ' (== header SPS)' if s in hdr else ''
        shown = ', '.join(f'{t:.3f}s' for t in times[:15] if t is not None) + (' ...' if len(times) > 15 else '')
        print(f'  x{len(times)}{same} at [{shown}]\n     {parse_sps(s)}')
    parsed = [parse_sps(s) for s in hdr + list(groups)]
    bad = 0
    if any('VUI_FPS' in d and not 1 <= d['VUI_FPS'] <= 120 for d in parsed):
        print('RED FLAG: VUI timing claims an absurd frame rate (> 120 or < 1 fps) -> fix with: '
              'mkvmerge --fix-bitstream-timing-information <TID>:1'); bad = 1
    if any(d.get('bit_depth_luma', 8) > 8 for d in parsed):
        print('RED FLAG: bit depth > 8 (High10) -> not supported for H.264; re-encode needed, ASK USER'); bad = 1
    sys.exit(bad)


if __name__ == '__main__':
    main()
