# Recipes: diagnose, fix, verify, swap in

Placeholders in the examples (replace them with your own paths):
- `<movies>`: the folder with the file(s) to fix;
- `<work>`: a work folder on a fast local disk (SSD), with free space for the fixed files;
- `<backup>`: a backup folder on the same drive as `<movies>`;
- `<drive>`: the mount point of the drive the TV plays from (only for test clips and `lsof`).

All scripts accept `-h`/`--help`.

## 1. Diagnosis

### 1.1 Drive health first

```bash
journalctl -k --no-pager | grep -E 'critical medium error|I/O error, dev sd'
sudo smartctl -a -d sat /dev/sdX      # the owner runs it (needs sudo); check attributes 5, 196, 197, 198, 199, 192
```

- `Current_Pending_Sector` > 0: the drive has unreadable sectors. The drive firmware resolves them (rewrites or
  reallocates) only when that LBA is **written** again.
- `Reallocated_Sector_Ct` > 0: sectors were already remapped.
- `Power-Off_Retract_Count` close to `Power_Cycle_Count`: the drive is routinely unplugged or powered off without
  ejecting (for example the TV cutting USB power). That is an emergency head retract each time.
- ffmpeg/ffprobe `Input/output error` / `Read error` point at **the drive**, not the file. Map bad LBAs to files with
  `scripts/badsector_map.sh /dev/sdX1 "<movies>"` (metadata-only).
- On a degrading drive, **minimize full reads**: copy each source to `<work>` once (watch the kernel log), do all
  further reads from the copy, and keep the packet-table CSV so the source never has to be re-read for comparison.

### 1.2 Header inventory (cheap)

```bash
scripts/inspect.sh "<movies>"      # a folder, or single files
```

It prints container, tracks (codec, codec ID, language/IETF, name, default/forced/enabled, channels, size),
attachments, chapters, DocType, tags and the encoder string, plus automatic `RED FLAG:` lines:
unsupported audio/video/subtitle codecs, picture tracks, disabled tracks, attachments, IETF elements, Matroska
header compression, non-8-bit/non-4:2:0 or interlaced video, DivX packed bitstream, AVI > 2 GiB, `.m4v`, and for a
folder: external subtitles with a non-matching name, a non-UTF-8 charset, or ASS/SSA format.
Manual equivalents: `mkvmerge -J FILE | jq`, `ffprobe -show_streams FILE`, `mkvinfo FILE` (stops at the first cluster).

### 1.3 Codec-level checks

**H.264: check every SPS, not just the header:**
```bash
python3 -I scripts/h264_sps_report.py FILE
```
- **`VUI_FPS`** = time_scale / (2·num_units_in_tick), plus `fixed_frame_rate`. A value like **90000 fps** (VFR timing
  from an m2ts timebase) makes the TV see an absurd frame rate. Exit code 1 flags it.
- `profile_idc`: 100 = High is OK; 110 = High10 is **not** supported. `level_idc`: FHD ≤ 42. `bit_depth_*` must be 8.
  `frame_mbs_only` = 0 means interlaced.
- `max_num_ref_frames` must fit the DPB for the level and resolution: L4.1/4.2 MaxDpbMbs = 32768, so at 1080p
  (8160 MBs) ≤ 4 refs, and at 1280×544 (2720 MBs) ≤ 12.
- **Several distinct SPS** = a spliced/edited stream. Note the timestamps: a playback glitch at a splice comes from the
  source.

**MPEG-4 ASP (DivX/Xvid):**
```bash
scripts/mpeg4_asp_check.sh FILE.avi          # GMC warp points, qpel, frame types, packed B-frames (decodes 3000 frames)
python3 -I scripts/mpeg4_vol.py FILE.avi     # VOS/VOL header fields, user data (Xvid build, DivX tag), in-band VOLs
python3 -I scripts/avi_headers.py FILE.avi   # AVI stream headers (compare with a playing AVI)
```
- `w:N` = GMC warp points. **N ≥ 2 is unsupported**, which means a lossy re-encode: **ask**.
- `qpel`: quarter-pel isn't mentioned in the spec. Flag it as a risk.
- **Packed B-frames** (DivX user data ends in `p`, e.g. `DivX503b1393p`) are fixable losslessly (§2).
- **Drop frames**: video packets of 0–7 bytes (`packet_scan.py` lists them) are not-coded VOPs. Each holds the previous
  picture for one frame slot. They are normal in VirtualDub/Xvid AVIs. A native-mode remux drops them, so it then needs
  a timestamp file (§2, "Native MPEG-4"). Packets of 8+ bytes can be real, nearly empty B-frames.
- A clean AVI has `avih` flags `0x110` (HASINDEX|ISINTERLEAVED), an `idx1` after `movi`, and stream lengths that agree
  with the duration.

**Audio:** an AC-3 track can be E-AC-3 behind an `A_AC3` ID. Check the bitstream id: bsid ≤ 8 is AC-3, 16 is E-AC-3
(bsid 6, Annex D, is normal AC-3).
```bash
for a in 0 1 2; do ffmpeg -v error -i FILE -map 0:a:$a -c copy -t 2 -f ac3 -y /tmp/a.ac3 && python3 -I -c 'import sys; d=open(sys.argv[1],"rb").read(); i=d.find(b"\x0b\x77"); print(sys.argv[2], "bsid", d[i+5]>>3)' /tmp/a.ac3 $a; done
```

### 1.4 Full packet scan (one full read; keep the CSV)

```bash
python3 -I scripts/packet_scan.py FILE --keep-csv <work>/<name>.pk.csv
```
Per-stream packet counts, DTS going backwards, the **peak 1-second video bitrate**, the longest GOP, drop frames and
read errors (exit code 1). For reference: a playing H.264 file peaked at 15.8 Mbps; MPEG-4 ASP is specified up to
20 Mbps, and peaks of 24–35 Mbps may stall playback there (only a re-encode changes that: ask).
**The CSV is your insurance:** if the source becomes unreadable later, a remux can still be compared packet by packet.

### 1.5 Compare failing vs playing files (the decisive step)

Ask the owner which files play and which don't, and **what the TV shows** (error message, sound without picture...).
Build a difference table across everything 1.2–1.4 print: VUI timing, SPS count, encoder options and build, header
fields (`avi_headers.py`), attachments, tags, IETF, chapters, track count, channels, peak bitrate, writing app.
Whatever the failing files have and the playing ones don't is the candidate list. Example (Alien 1 plays, Prometheus
and Romulus don't):

| Property | Alien 1 (plays) | Prometheus (fails) | Romulus (fails) |
|---|---|---|---|
| VUI frame rate | 23.976 CFR | **90000 VFR** (+1 spliced SPS at 23.976) | 24.000 CFR |
| Tags (stats) | none | yes | yes |
| Attachments | none | none | **cover.jpg** (an MJPEG "video" stream) |
| IETF language elements | none | none | **yes** |
| Chapters | none | none | 21 |
| Tracks | 6 | 7 | **10** |
| Peak video bitrate | 15.8 Mbps | 50 Mbps | 11.7 Mbps |

**Not causes** (seen on playing files too, or harmless): Matroska `DocTypeVersion 4 / ReadVersion 2`; the track
`Lacing` flag; AC-3 bsid 4/6/8.

**Never declare a file "in spec, so it plays"** without the owner's confirmation: Sherlock S1 was in spec on paper
and still refused (docs/case-log.md).

### 1.6 External subtitle files

```bash
ls "<movies>"; file -i "<movies>"/*.srt
iconv -f cp1251 -t utf-8 "X.RUS.srt" | head -20     # readable Cyrillic = cp1251
```
- `file` reports Russian cp1251 text as `iso-8859-1` / `unknown-8bit`. UTF-8 files may have a BOM (mkvmerge handles it).
- The name tells the language and the forced flag (`.ENG.srt`, `.RUS.Forced.srt`). "Forced" subtitles translate only
  on-screen text and signs, for viewers of the dubbed audio.
- ASS/SSA files are often **typeset** (`\pos`, `\move`, `\frz`, fonts, colours): converting to SRT keeps text and timing
  but loses all placement. That is lossy: **ask**.
- Check that the timing fits: the last cue should be before the end of the video.

## 2. Fix recipes (lossless)

Always write to `<work>`, never in place on the movie drive: `mkvmerge -o "<work>/out/Name.mkv" [options] "<movies>/Name.ext"`.
mkvmerge exit codes: **0** = OK, **1** = warnings (read them!), **2** = error.
Standard options for a "classic" MKV: `--disable-language-ietf --disable-track-statistics-tags --no-global-tags`
(mkvmerge v65 *adds* IETF elements by default even if the source had none).

| Problem | Lossless fix |
|---|---|
| H.264 VUI timing wrong (e.g. 90000 fps VFR) | `--fix-bitstream-timing-information 0:1` (TID of the video track). Rewrites the header **and all in-band SPS** to the container frame rate. Verified on real files. |
| Attachments (cover art, fonts) | `-M` / `--no-attachments` |
| IETF BCP47 language elements | `--disable-language-ietf`. In place on an existing file: `mkvpropedit F --edit track:1 --delete language-ietf --edit track:2 --delete language-ietf ...` |
| Statistics / other tags | `--disable-track-statistics-tags --no-global-tags --no-track-tags` |
| Matroska header compression (old mkvmerge 4.x–6.x files) | remux with `--compression -1:none` |
| **Xvid/DivX AVI the TV refuses** (or any MPEG-4 ASP for this TV) | **Native MKV:** `mkvmerge -o out.mkv --engage native_mpeg4 [standard options] in.avi [subtitles]`. Stores `V_MPEG4/ISO/ASP` with CodecPrivate = the VOL; native mode ignores the AVI's BITMAPINFOHEADER. First run `packet_scan.py`: **no drop frames** → done (expect `[NOTE] constant ... +40 ms` at 25 fps / `+42 ms` at 23.976/24 fps in `verify_remux.sh`). **Drop frames** → next row. Proven on the QE55QN80H (Sherlock S1–S4). |
| **Native MPEG-4 with drop frames** | 1. `python3 -I scripts/ts_v2_from_frames.py in.avi > ts.txt` (one gap per drop frame; stderr shows the count). 2. `mkvmerge -o out.mkv --engage native_mpeg4 --timestamps 0:ts.txt [same options] in.avi [subtitles]`. 3. `verify_remux.sh` must report a *constant* offset. Without the timestamp file the video runs ahead of the audio after the first drop frame. |
| DivX **packed B-frames** | Same native-mode remux: the frames are unpacked (ffmpeg's "packed B-frames" warning disappears, decoded frames identical). Alternative: `ffmpeg -i in.avi -map 0 -c copy -bsf:v mpeg4_unpack_bframes out.mkv`. |
| AVI > 2 GiB, HEVC in AVI | plain remux to MKV: `mkvmerge -o out.mkv in.avi`. Default (VFW) mode keeps every AVI frame with the AVI's own timing (timestamps verify identical), but this TV refused one Xvid stream in VFW mode, so for MPEG-4 ASP prefer native mode (rows above). |
| AVI with a lavf-style video header (`strf` biSize = 40 + VOL extradata, bitcount 24) | Only if the file must stay an AVI: `scripts/avi_fix_bih.py COPY.avi` normalizes the header in place (header bytes only; prove with `cmp -l`). It did **not** make Sherlock S1 play; native MKV did. |
| **External `.srt` files** (wrong name for the TV, cp1251, several languages) | Mux them in; each file's options go *before* that file: `... in.avi --language 0:rus --sub-charset 0:cp1251 --forced-display-flag 0:1 --default-track-flag 0:1 --track-name 0:Forced X.RUS.Forced.srt --language 0:eng --default-track-flag 0:0 X.ENG.srt`. The charset conversion is exact. Make a *forced* track default when the default audio is the dub; full-text subtitles stay non-default. Move the `.srt` files into the backup together with the source. |
| AVI audio/video tracks have no language | Set `--language 1:rus` etc. only when the owner confirms which track is which; otherwise leave `und`. |
| Truncated last (or first) audio frame (e.g. a 192-byte piece of a 768-byte AC-3 frame at the end of an AVI) | Nothing to do: mkvmerge's parser drops it, and no decoder could play it. `verify_remux.sh` reports `[OK~]`. |
| H.264 level flag too high but the stream really fits a lower level | `ffmpeg -i in.mkv -map 0 -c copy -bsf:v h264_metadata=level=4.1 out.mkv` (mkvtoolnix can't). Use `4`, `4.1`, `4.2` or `41`; **`4.0` silently writes the invalid level_idc 4**. Check refs/DPB and bitrate against that level first; otherwise it's a lie and needs a re-encode: **ask**. |
| E-AC-3 hidden behind `A_AC3` | a plain mkvmerge remux re-detects it and writes `A_EAC3` |
| Wrong default/forced flags | `mkvpropedit F --edit track:N --set flag-default=0 --set flag-forced=0` (header-only, in place; mkvpropedit numbers tracks from 1). Note: mkvpropedit may move the Tracks element into the Void ahead of Segment info (valid Matroska). |
| **iTunes-style MP4/M4V**: `.m4v` extension, `tx3g` subtitles (mkvmerge can't read them), tracks marked *disabled* (Apple alternate groups), JPEG chapter-thumbnail "video" track, cover | Subtitles: `ffmpeg -i in.m4v -map 0:s:N -c:s srt s.srt`, strip the font-size tags ffmpeg adds (`sed -E 's#<font size="[0-9]+">##g; s#</font>##g'`), keep `<i>`, prove with `scripts/tx3g_compare.py in.m4v N s.srt`. Then `mkvmerge -o out.mkv [standard options] -M -d 0 --track-enabled-flag 1:1 ... --default-track-flag ... in.m4v --language 0:rus --default-track-flag 0:0 s.srt ...` (`-d 0` keeps only the real video). Chapters carry over. Also run `h264_sps_report.py` (it reads the MP4 avcC). |
| Unwanted extra tracks | `-a 1,3` / `-s 4` / `-A` / `-S` / `-d 0`. Dropping tracks is not "breaking" the file, but **ask** before removing audio or subtitles. |

**Needs re-encoding or other lossy work: flag it and ask** (suggest the least lossy option):
- DTS / TrueHD / (Opus) audio: suggest adding an AC-3 640k or E-AC-3 track and keeping the original track as a
  non-default track only if the TV tolerates it.
- 10-bit or 4:2:2 H.264, VC-1/WMV, RealVideo, MPEG-4 with GMC ≥ 2: suggest a re-encode to H.264 8-bit or HEVC.
- Video bitrate peaks above the codec's limit (e.g. MPEG-4 ASP > 20 Mbps): playback may stall at those moments.
- ASS/SSA → SRT: positions and styles are lost (`ffmpeg -i in.mkv -map 0:s:N -c:s srt out.srt`); or leave it out.
- PGS/VobSub → text: OCR is lossy.

**Test risky options on a sample first** (seconds instead of minutes):
```bash
mkvmerge -o <work>/sample.mkv --split parts:00:10:00-00:12:00 [options] in.ext
```

**Remux what's needed, not more:** keep every track, track names, languages, flags and chapters unless one of them is a
suspect. Normalize a whole library only if the owner asks for it.

## 3. Verification: prove the remux is lossless

```bash
scripts/verify_remux.sh ORIG NEW <work>/verify_<name>     # reads both files fully, in parallel; exit 0 = VERIFIED
```
1. **Track list:** same codec, language, name, flags, channels and size; across containers (AVI/MP4 → MKV) type, codec,
   channels and size only.
2. **Audio + subtitles:** per-packet `framemd5` must be identical; across containers a per-stream payload hash instead.
   If a hash differs, the script checks whether NEW equals ORIG minus an incomplete first or last frame (`[OK~]`).
3. **Video:** the MD5 of **every decoded frame** must be identical, which proves bit-exact pictures even when headers
   were rewritten. ffmpeg would pick the MPEG-4 ASP IDCT from the container FourCC, so the script pins `-idct simple`.
   **Frame timestamps** are compared too:
   - `[OK] frame timestamps identical`: plain remux (including AVI → MKV in VFW mode);
   - `[NOTE] constant frame-timestamp offset`: native-mode MPEG-4 with B-frames (AVI has no PTS, so the AVI decode
     runs one frame late). A spread ≤ 2 ms counts as constant: Matroska stores whole milliseconds;
   - `[FAIL] ... non-uniformly`: A/V sync would shift mid-file → timestamp file (§2).
4. Decoder/demuxer messages are listed; `Input/output error` means a drive problem (§1.1).

**Muxed-in external subtitles:** `ALLOW_ADDED_SUBS=1 scripts/verify_remux.sh ORIG NEW` leaves subtitle tracks out of
checks 1–2 and lists them. Then prove each one:
```bash
python3 -I scripts/srt_compare.py X.RUS.Forced.srt NEW.mkv 3 --charset cp1251   # TID from inspect.sh
python3 -I scripts/srt_compare.py X.ENG.srt NEW.mkv 4
```
It compares every cue's start, end and text after normalizing BOM, CRLF and numbering, fails on `U+FFFD` (a wrong
`--sub-charset`), and prints the track's language/default/forced flags.

**When the source can no longer be read fully** (bad sectors appeared mid-session):
- compare the decoded/packet hashes up to the read error (the first N lines);
- compare the packet-table CSV from §1.4 with a fresh `ffprobe -show_packets` of the new file: same pts/dts for all
  packets, equal sizes except the expected rewritten packets (in the Prometheus case exactly 11 SPS-bearing packets,
  each 1 byte shorter);
- run `h264_sps_report.py NEW` to confirm that all SPS are fixed.

## 4. Swap in

```bash
scripts/swap_in.sh "<work>/out/Name.mkv" "<movies>/Name.avi" "<backup>"
```
- **Moves** the original to `BACKUP_ROOT/<same path below the mount point>` (a rename on the same volume: no data I/O).
- Copies the new file in (the extension follows the new file), fsyncs, drops both files from the page cache and
  **byte-compares**, so the comparison really reads the disk. Reports new kernel disk errors. Refuses to overwrite.
- The backup folder **is visible in the TV's file browser**: tell the owner so they don't play the old file.
- Replacing an earlier fix of your own (not an original): write the new file under a temporary name next to the old
  one, fsync, drop the cache, `cmp`, then rename it over the old one.

Keep the copy in `<work>` until the owner has confirmed TV playback. Delete backups and work copies **only on the owner's
explicit yes**. Deleting a backup that contains pending bad sectors lets the drive resolve them when the space is reused.

## 5. If the TV still refuses: bisect with clips

The TV can't be simulated. Make 2-minute clips that each remove one more suspect, put them in a test folder on the
drive, and let the owner try them all in one trip. Ask what each one does (plays / error / no picture / no sound).

H.264 MKV (adjust the track IDs):
```bash
IN="<file>.mkv"; O="<drive>/_tv_test"; mkdir -p "$O"; C='--split parts:00:10:00-00:12:00'
mkvmerge -q -o "$O/A_as_is.mkv"        $C "$IN"
mkvmerge -q -o "$O/B_no_attach.mkv" -M $C "$IN"
mkvmerge -q -o "$O/C_min.mkv"       -M --no-chapters --no-global-tags -T --disable-track-statistics-tags --disable-language-ietf -a 1 -s 4 $C "$IN"
mkvmerge -q -o "$O/D_video_only.mkv" -A -S -M --no-chapters --no-global-tags -T --disable-track-statistics-tags --disable-language-ietf $C "$IN"
mkvmerge -q -o "$O/E_vui_fixed.mkv"  -A -S -M --no-chapters --no-global-tags -T --disable-track-statistics-tags --disable-language-ietf --fix-bitstream-timing-information 0:1 $C "$IN"
```
Reading: A plays → the remux alone fixes it. D fails → the video bitstream (SPS/level/profile/refs). D fails, E plays →
VUI timing.

Xvid/DivX AVI (this set found the Sherlock fix):
```bash
mkvmerge -q -o "$O/A_current.mkv" $C "<current file>"                     # control: must fail like the full file
ffmpeg -ss 600 -t 120 -i in.avi -map 0 -c copy "$O/B_avi_fixed_header.avi" && python3 -I scripts/avi_fix_bih.py "$O/B_avi_fixed_header.avi"
mkvmerge -q -o "$O/C_mkv_vfw.mkv" $C in.avi                               # VFW mode (V_MS/VFW/FOURCC)
mkvmerge -q -o "$O/D_mkv_native.mkv" --engage native_mpeg4 $C in.avi     # native (V_MPEG4/ISO/ASP)
```
A mkvmerge or ffmpeg cut is itself a remux: to reproduce the exact original, ask the owner to test the original file.
Afterwards ask the owner to delete the test folder (an agent's `rm` of a top-level drive folder may be blocked).

## 6. Pitfalls (agent operations)

- **Unmount blocked**: a shell or agent session whose working directory is on the drive keeps it busy, and so does a
  file manager. `lsof +f -- <drive>` shows who. Work from `<work>`; tell the owner to **eject** properly (§1.1).
- `pkill -f '<pattern>'` also kills your own shell if the pattern appears in its command line; a watcher like
  `while pgrep -f '<pattern>'` matches itself and never ends. Use PIDs.
- ffmpeg 4.4 `trace_headers` prints only at `-loglevel debug`.
- `mkvextract` has no "codecprivate" mode: use `mkvmerge -J FILE | jq '.tracks[].properties.codec_private_data'` (hex),
  or `ffprobe -show_streams -show_data` (extradata) for MP4.
- `mkvinfo` without `-a` stops at the first cluster, so Tags and Cues at the end aren't shown: use
  `mkvextract FILE tags -`. `mkvinfo -a` on a 10 GB file prints every block (very slow).
- `ffprobe -show_packets` on a 10 GB file takes minutes on USB. Do header work meanwhile, but **don't run two full
  reads of the same HDD in parallel**: seeking slows both. Writing to `<work>` then copying beats read+write on one HDD.
- `filefrag -v` works on ntfs3; physical offsets are FS blocks from the partition start:
  `block = (LBA - partition_start) * 512 / blocksize`. One-block files print `1 block of 4096 bytes` (singular).
- **`--engage native_mpeg4` is an undocumented hack** (only in `mkvmerge --engage list`). It drops Xvid/DivX drop frames
  and closes their time slots. The decoded pictures stay identical, but without a timestamp file the video runs ahead
  of the audio from the first drop frame on.
- `verify_remux.sh` reads both files fully. Run a season's episodes in parallel from the SSD (3–4 at a time), not from
  the USB drive.
- ffmpeg's `h264_metadata=tick_rate=X` sets time_scale/num_units_in_tick = X (the help text says the inverse).
