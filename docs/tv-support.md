# What the TV supports

The rules in this repo were built for a **Samsung QE55QN80H (2026 Neo QLED 4K)**. Samsung's developer site puts it in
the platform tier **`26TV_PREMIUM2` (UHD)**. Samsung publishes media specifications per **year and tier**, not per model,
so the spec part below applies to every 2026 model in that tier.

## How much of this repo carries over to another TV

| Layer | Where | Carries over? |
|---|---|---|
| Analysis and verification tools | `scripts/` (everything except the RED FLAG rules) | Yes, to any player. They only read files and prove that a remux changed nothing. |
| Spec rules | this file, the RED FLAG rules in `scripts/inspect.sh`, `h264_sps_report.py` | To all 2026 `26TV_PREMIUM2` models. For another year or tier, re-read that tier's table (links below) and update this file and the flags. |
| Observed behaviour | "Observed on the QE55QN80H" below, `docs/case-log.md` | Proven on one TV and its firmware only. TVs on the same platform probably behave alike, but firmware updates can change it. |

Decoding happens in the TV's SoC; file parsing in Samsung's Tizen player. The Sherlock case suggests that some refusals
come from the player/demuxer, not the decoder: the same Xvid bitstream was refused in AVI and in VFW-mode MKV, but
played as native MPEG-4 in MKV.

## Samsung 2026 spec, tier `26TV_PREMIUM2`

Source: Samsung developer "2026 TV Video Specifications". The page's tables are flattened in its HTML, so the pairing
of resolution, fps and bitrate is slightly uncertain. Re-read the page if a limit matters.

**Containers:** AVI, MKV, ASF, MP4, 3GP, MOV, FLV, VRO, VOB, PS, TS (and M2TS/MTS), WebM.
File extensions not on Samsung's list (for example `.m4v`) may not show up at all.

**Video codecs:**

| Codec | Limits / notes |
|---|---|
| **H.264** BP/MP/HP | FHD: **Level ≤ 4.2** (FMO/ASO/RS not supported). UHD: Level ≤ 5.1. Up to ~60 Mbps. **8-bit 4:2:0 only** (High10 / 4:2:2 profiles are not listed, so they are unsupported). |
| **HEVC** Main/Main10 | FHD L4.1, UHD L5.2. **Only in MKV/MP4/TS** (not AVI). |
| **MPEG-4 SP/ASP** (DivX/Xvid) | ≤ 1920×1080@60, **20 Mbps**. **"GMC 2 and higher: Not supported."** |
| MS MPEG-4 v1/2/3, MPEG-1/2, H.263 Sorenson, VP6, Motion JPEG | listed |
| AV1 | ≤ 3840×2160@120, 40 Mbps |
| VP8 / VP9 | in WebM |
| **VC-1/WMV9, RealVideo/RMVB** | **not listed for 2026** (RV/RA/RMVB explicitly dropped) |

**Audio:** AC3, DD+ (E-AC-3, 5.1), AAC/HE-AAC, MP3, LPCM, ADPCM, AC-4, OPUS (in the spec).
**DTS: explicitly not supported on 2026 TVs.** **TrueHD: not listed.**
The owner's own list is "AAC/AC-3/E-AC-3 OK; no DTS/TrueHD/Opus". The spec lists Opus, but treat Opus as unsupported
unless tested.

**Subtitles:** SRT (`S_TEXT/UTF8`) inside MKV works. **No ASS/SSA** (owner's note). PGS/VobSub are untested, so assume
they are unsupported. **External** `.srt` files: Samsung TVs commonly pick up an external subtitle only if its name is
exactly the video's name with `.srt` (`Movie.avi` + `Movie.srt`; not tested on this TV), so `Movie.ENG.srt` or
`Movie.RUS.Forced.srt` are ignored, and only one external file can match. Non-UTF-8 files (cp1251) depend on the TV's
subtitle-encoding setting. The robust fix is to mux them into an MKV as UTF-8 tracks (docs/recipes.md).

**General notes from the spec:**
- "Media cannot be played if the file is corrupted or the information in the container is wrong."
- "Media with higher bit or frame rate than specifications can cause video or audio playback to stall."
  This is the key to the 90000 fps VUI cases in `docs/case-log.md`.

## Observed on the QE55QN80H (evidence in docs/case-log.md)

| Observation | Confidence |
|---|---|
| H.264 whose SPS VUI claims 90000 fps VFR (`time_scale 180000 / num_units_in_tick 1`) does not play; `mkvmerge --fix-bitstream-timing-information` fixes it. | Confirmed (Prometheus). Same defect fixed in Covenant, playback not reported. |
| An H.264 MKV with a cover attachment, IETF language elements, stats tags and 10 tracks did not play; a remux without attachments/IETF/tags did. Which change mattered was not isolated. | Confirmed fix, cause unknown (Romulus). |
| An Xvid ASP AVI (XviD0047, B-frames) did not play as AVI, nor as VFW-mode MKV (`V_MS/VFW/FOURCC`), even with a normalized BITMAPINFOHEADER. As native MKV (`V_MPEG4/ISO/ASP`, `--engage native_mpeg4`) it played. | Confirmed with A/B test clips (Sherlock S1). |
| Many other Xvid AVIs (XviD0063–0073, AC-3) on the same drive play as AVI. Why Sherlock S1 differs is unknown. | Owner's report. |
| MKV with S_TEXT/UTF8 subtitles (forced + default flags) plays and shows them. | Confirmed (Sherlock S1). |

## Sources

- Samsung 2026 TV Video Specifications: https://developer.samsung.com/smarttv/develop/specifications/media-specifications/2026-tv-video-specifications.html
- Samsung TV model groups (QN80H → 26TV_PREMIUM2): https://developer.samsung.com/smarttv/develop/specifications/tv-model-groups.html
- 2025 spec (for comparison): https://developer.samsung.com/smarttv/develop/specifications/media-specifications/2025-tv-video-specifications.html
- Samsung media specifications index: https://developer.samsung.com/smarttv/develop/specifications/media-specifications.html
- mkvmerge manual: `man mkvmerge` (`--fix-bitstream-timing-information`, `--disable-language-ietf`, timestamp files).
  `--engage native_mpeg4` is listed only by `mkvmerge --engage list`.
