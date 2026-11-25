# Case log

Real sessions on the QE55QN80H, newest last. Each entry: what was found, what was done, how it was verified and
what the owner reported. Add an entry after every session (AGENTS.md, "Maintaining this repo").
`<drive>` = the USB movie drive (a 4 TB 2.5" USB HDD, NTFS via ntfs3), `<work>` = the SSD work folder.

## 2026-11-21 — `Movies/Kids/Aliens` (H.264 MKVs, Xvid/DivX AVIs)

| File | Finding | Action | Result |
|---|---|---|---|
| Прометей (2012).mkv | H.264 High@4.1, 1280×536. **Header + 10 in-band SPS: VUI 90000 fps VFR** (time_scale 180000 / num_units 1); spliced stream: 1 different SPS at 4100.5 s (23.976 CFR); splice region 1:07:36–1:08:20 gives decoder warnings (source issue); peak 50 Mbps | `--fix-bitstream-timing-information 0:1`, stats tags dropped, IETF elements removed | Verified (packet table + partial decode: the drive developed bad sectors in this file mid-session). **Plays.** |
| Чужой. Ромул (2024).mkv | H.264 L4.1, x264 ref=11 bframes=15; packets clean. Suspects: cover.jpg attachment, IETF elements, stats tags, 10 tracks, chapters | `-M --disable-language-ietf --disable-track-statistics-tags --no-global-tags --no-track-tags` (tracks and chapters kept) | Fully verified bit-exact. **Plays.** Which change mattered was not isolated; try the attachment removal first next time. |
| Чужой 1 (1979).mkv | H.264, AC-3 2.0, SRT, no tags/attachments | none | Plays (reference file). |
| Чужой 2/3 (.avi) | DivX 5.03 (**packed B-frames**), hpel, no GMC, 2× AC-3 5.1, > 2 GiB AVI | not touched | — |
| Чужой 4 (.avi) | Xvid 0050, not packed, no GMC, 2× AC-3 5.1, > 2 GiB AVI | not touched | — |

Drive: during verification the kernel logged *unrecovered read errors*. SMART: `Current_Pending_Sector 7`,
Reallocated 0, `Power-Off_Retract_Count` 1576 of 1689 power cycles (the drive is usually unplugged without ejecting).
The bad LBAs were inside the Prometheus original (at 122–127 MB). The owner later deleted the backups, which frees
those sectors for rewriting.

## 2026-11-21/22 — `Movies/Adventure/Sherlock/Season 1` (Xvid AVI + external SRT)

| Item | Finding |
|---|---|
| `Sherlock.s01e0{1,2,3}.avi` (1.5 GB each) | VirtualDubModRus; Xvid (`XviD0047`) ASP L5, 720×400, 25 fps, hpel, no GMC, not packed, B-frames; AC-3 2.0 192k + AC-3 5.1 448k; clean `idx1`, interleaved; peak video 8.5–17 Mbps; no read errors. Video `strf` is lavf-style (biSize 81 with VOL extradata, bitcount 24), unlike 13 other Xvid AVIs on the drive (biSize 40, bitcount 12). |
| Drop frames | e01: none; e02: 1 (at the very end); e03: 6 at 3997–4052 s |
| e03 audio 2.0 | ends with a truncated 192-byte AC-3 fragment (harmless) |
| Subtitles | `*.ENG.srt` UTF-8 with BOM; `*.RUS.Forced.srt` **cp1251**; names don't match the video |

Timeline:
1. First diagnosis: "video/audio in spec, the problem is the subtitles". AVI → MKV in **VFW mode** with both SRTs muxed
   in; verified (frames and timestamps identical). A first try with `--engage native_mpeg4` was rejected because e03's
   timestamps drifted at the drop frames.
2. **The owner: "still can't be played"** (the AVIs hadn't played either). Lesson: ask for the symptom and compare with a
   *playing* file of the same codec before calling a file "in spec".
3. Test clips (10:00–12:00 of e01): A = current VFW MKV (control), B = AVI with normalized header (`avi_fix_bih.py`),
   C = VFW MKV from the normalized AVI (40-byte CodecPrivate), D = native MKV (`V_MPEG4/ISO/ASP`).
   **Only D played.** So the header was not the cause; the TV refuses this stream in AVI and VFW-mode MKV.
4. Final fix: native mode, with the original timing restored by a v2 timestamp file (now `ts_v2_from_frames.py`).
   Verified: decoded video identical; timestamps a constant +40 ms on all three episodes; audio identical (e03 minus
   the 192-byte fragment); all cues identical. Audio languages set (2.0 = rus, 5.1 = eng, confirmed by the owner).
   **The owner confirmed playback.** Why other Xvid AVIs on the drive play as AVI is still unknown.

## 2026-11-22 — `~/Videos/Чужой. Наследие (2017).m4v` (iTunes M4V)

A copy of another file, which served as the backup. No symptom given.

| Item | Finding |
|---|---|
| Video | H.264 High@3.1, 1280×536, 23.976 CFR. **SPS VUI: 90000 fps VFR** (the Prometheus defect) |
| Audio | AAC 2.0 rus (enabled), AAC 2.0 eng, AC-3 5.1 rus, AC-3 5.1 EX eng (the last three *disabled*) |
| Subtitles | 2× tx3g (rus 1439, eng 1450 cues; 271 italic each) |
| Extras | JPEG chapter-thumbnail track, `cover.jpg`, 24 chapters, iTunes tags; `.m4v` extension |

Fix: subtitles to SRT (font-size tags stripped, italics kept), then `mkvmerge ... -M -d 0
--fix-bitstream-timing-information 0:1` with all tracks enabled; defaults: video, AAC rus; subtitles not default.
Verified: decoded video and timestamps identical (175 583 frames); 4 audio payloads identical; all cues identical
(`tx3g_compare.py` + `srt_compare.py`); the only track-list difference is the dropped JPEG track. The `.m4v` copy was
replaced by the `.mkv`. Playback not reported.

## 2026-11-23 — `~/Videos/Sherlock/Season 2–4` → `Season N_fixed/`

The owner confirmed Season 1 plays and asked for the other seasons in `Season N_fixed` folders (originals untouched).

| Item | Finding |
|---|---|
| S2 (3 ep.) | Xvid 0064 + `DivX503b1393` user data (**not** packed), 720×400@25, MPEG quant; 40-byte header with bitcount 24; 2× AC-3 2.0; ENG.srt + **RUS.Forced.ass** (Aegisub typesetting: `\pos`, `\move`, `\frz`, colours, several fonts) |
| S3 (3 ep.) | Xvid 0067 via VirtualDubMod, 704×400@25, lavf-style header (biSize 209); AC-3 2.0 + 5.1; RUS.Forced.srt + ENG.srt; **1-s video peaks 24–35 Mbps** (above the 20 Mbps spec: a stall is possible there) |
| S4 (3 ep.) | Xvid 0073, 720×400@23.976, standard Xvid header; AC-3 2.0 + 5.1; full RUS.srt + ENG.srt |
| Special (Abominable Bride) | Xvid 0067, 704×384@24; 2× AC-3 5.1 384k; RUS.FORCED.srt + ENG.srt |
| All | no GMC, qpel, interlace, packed B-frames or drop frames |

Fix: `--engage native_mpeg4` straight from the originals (native mode ignores the AVI header: CodecPrivate and packets
were identical from a patched and an unpatched AVI). Subtitle flags: forced RUS = forced + default; full RUS and ENG
not default. Audio languages left `und` (unknown).
Verified, all 10: decoded video identical; timestamps a constant +40 ms (25 fps) / +42 ms (23.976/24 fps); audio
identical minus incomplete final frames (192–995 bytes); all 17 SRT tracks identical.
The owner chose to **leave S2's typeset ASS subtitles out** rather than convert them to SRT.
