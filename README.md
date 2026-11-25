# samsung-tv-movie-fix

Find out why a Samsung TV refuses a movie file, fix it **without re-encoding**, and **prove** that the fixed file
carries exactly the same pictures, sound and subtitles as the original.

The fixes are remuxes with mkvtoolnix (new container, same streams), header rewrites, and muxing external subtitles
into the file. Every fix is checked frame by frame and packet by packet before it replaces anything, and originals are
kept as backups. Anything that would need lossy work (re-encoding video or audio, converting styled subtitles) is
reported, not done.

Built and tested against a **Samsung QE55QN80H (2026)**, Samsung platform tier `26TV_PREMIUM2`. The tools work for
any TV; the "what is supported" rules apply to Samsung's 2026 `26TV_PREMIUM2` models. See
[docs/tv-support.md](docs/tv-support.md) for what carries over to other TVs.

## Requirements

Linux with these tools (tested on Ubuntu 22.04; versions in brackets are the tested ones):

| Tool | Package (Debian/Ubuntu) | Needed for |
|---|---|---|
| mkvmerge, mkvinfo, mkvextract, mkvpropedit (65.0.0) | `mkvtoolnix` | all remuxes; `--engage native_mpeg4` must exist |
| ffmpeg, ffprobe (4.4.2) | `ffmpeg` | inspection, decoding for verification; bsfs `h264_metadata`, `trace_headers`, `filter_units` |
| python3 ≥ 3.8 (3.10) | `python3` | the `.py` scripts (standard library only) |
| jq (1.6) | `jq` | reading `mkvmerge -J` output |
| file, strings, numfmt, cmp, iconv, findmnt | `file`, `binutils`, `coreutils`, `diffutils`, `libc-bin`, `util-linux` | small helpers (usually preinstalled) |
| filefrag *(optional)* | `e2fsprogs` | `badsector_map.sh` |
| journalctl *(optional)* | `systemd` | kernel disk-error checks |
| smartctl *(optional, sudo)* | `smartmontools` | drive health (SMART) |
| lsof *(optional)* | `lsof` | finding what keeps a drive busy |
| shellcheck *(optional, dev)* | `shellcheck` | linting the shell scripts |

The smoke tests also need the ffmpeg encoders `libx264`, `mpeg4`, `ac3` and `mov_text` (Ubuntu's ffmpeg has them).

```bash
sudo apt install mkvtoolnix ffmpeg jq python3 file binutils e2fsprogs smartmontools lsof
scripts/check_deps.sh        # checks tools, versions and required features
tests/smoke.sh               # ~10 s, synthetic media only; must end with "0 failed"
```

No installation step: run the scripts from the repo (or put `scripts/` on your `PATH`).
Disk space: a fixed file is about the size of the original; keep a work folder on a fast local disk (SSD).

## Quick start

```bash
# replace the three placeholders with your own paths first
M="<movies>"    # folder with the file to fix
W="<work>"      # work folder on a fast local disk, with free space for the fixed file
B="<backup>"    # backup folder on the same drive as $M (the original is moved there)
mkdir -p "$W/out"

journalctl -k --no-pager | grep -E 'critical medium error|I/O error'   # 1. drive health first
scripts/inspect.sh "$M"                                                 # 2. header inventory + RED FLAGs
python3 -I scripts/packet_scan.py "$M/Film.avi" --keep-csv "$W/Film.pk.csv"   # 3. full read: errors, peaks, drop frames
mkvmerge -o "$W/out/Film.mkv" --disable-language-ietf --disable-track-statistics-tags --no-global-tags \
         --engage native_mpeg4 "$M/Film.avi"                            # 4. a fix (here: Xvid AVI -> native MKV)
scripts/verify_remux.sh "$M/Film.avi" "$W/out/Film.mkv" "$W/verify_Film"     # 5. proof: RESULT: VERIFIED
scripts/swap_in.sh "$W/out/Film.mkv" "$M/Film.avi" "$B"                # 6. swap in, keep the original as a backup
```
Then the owner tests on the TV. Delete backups only after that. The full procedure, with every known problem and its
fix, is in [docs/recipes.md](docs/recipes.md).

## Tools

All scripts print their usage with `-h`/`--help`. "Reads" = how much of each input file is read.

| Script | Purpose | Reads | Writes | Exit codes |
|---|---|---|---|---|
| `check_deps.sh` | required/optional tools, versions, features | — | — | 0 ok · 1 missing |
| `inspect.sh FILE_OR_DIR...` | inventory: tracks, flags, attachments, tags, encoder; `RED FLAG:` lines; external subtitle check for folders | headers | — | 0 · 2 |
| `h264_sps_report.py FILE [IDX]` | every H.264 SPS (header + in-band): VUI frame rate, profile, level, refs | video stream | — | 0 ok · 1 absurd VUI / > 8-bit · 2 |
| `mpeg4_asp_check.sh FILE [N]` | DivX/Xvid: GMC warp points, qpel, frame types, packed B-frames | N frames | — | 0 ok · 1 GMC ≥ 2 · 2 |
| `mpeg4_vol.py FILE...` | DivX/Xvid VOS/VOL header fields, user data, in-band VOL count | first 8 MiB | — | 0 · 1 GMC ≥ 2 · 2 no VOL |
| `avi_headers.py FILE...` | AVI RIFF structure: avih, strh/strf, OpenDML, INFO, idx1 | headers | — | 0 · 2 not AVI |
| `packet_scan.py FILE [--keep-csv F]` | packet counts, DTS order, peak 1-s bitrate, GOP, drop frames, read errors | full | CSV | 0 · 1 read errors · 2 |
| `verify_remux.sh ORIG NEW [WORKDIR]` | **proof of losslessness**: tracks, audio/subtitle payload, every decoded frame, frame timestamps | full, both | WORKDIR | 0 VERIFIED · 1 FAILED · 2 |
| `srt_compare.py SRC.srt MKV TID [--charset C]` | muxed subtitle track == source .srt (timing + text) | MKV track | — | 0 same · 1 differs · 2 |
| `tx3g_compare.py MP4 IDX SRT` | converted SRT == MP4 timed-text track | subtitle stream | — | 0 · 1 · 2 |
| `ts_v2_from_frames.py ORIG [--shift-ms N]` | mkvmerge timestamp file restoring the original frame timing (native MPEG-4 with drop frames) | full decode | stdout | 0 · 2 |
| `avi_fix_bih.py COPY.avi [--dry-run]` | normalize an ffmpeg-style AVI video header **in place** (header bytes only) | headers | **the file** | 0 · 1 refused · 2 |
| `swap_in.sh NEW TARGET BACKUP_ROOT` | move the original to the backup, copy the fix in, read back from disk | full | drive | 0 · 1 refused/differs · 2 |
| `badsector_map.sh /dev/sdX1 PATH...` | which files contain the kernel-reported bad sectors (metadata only) | none | — | 0 none · 1 hit · 2 |

Exit code **2** always means a usage error, a missing tool or an unreadable input.

### Output conventions

Scripts print one finding per line, starting with a marker that is easy to grep:

| Marker | Meaning |
|---|---|
| `[OK]` | check passed |
| `[OK~]` | passed with an explained, harmless difference (e.g. an incomplete final audio frame dropped) |
| `[OK*]` | passed except repeated (duplicate) frames: check A/V sync on a sample |
| `[NOTE]` | expected difference (e.g. constant one-frame timestamp offset of a native MPEG-4 remux) |
| `[DIFF]` | difference found, explanation follows |
| `[WARN]` | needs attention (decoder messages, new kernel disk errors) |
| `[FAIL]` | check failed |
| `RED FLAG:` | something the TV may not accept; the line names the fix or says ASK USER |
| `RESULT: VERIFIED` / `RESULT: FAILED` | final verdict of `verify_remux.sh` |

## Documentation

- [docs/recipes.md](docs/recipes.md) — diagnosis, every known fix, verification, swap-in, test clips, pitfalls.
- [docs/tv-support.md](docs/tv-support.md) — what the TV supports (spec + observed behaviour), portability.
- [docs/case-log.md](docs/case-log.md) — real cases: symptoms, findings, fixes, results.
- [AGENTS.md](AGENTS.md) — rules and workflow for AI agents (also a good checklist for people).

## Repository layout

```
scripts/     the tools (bash + python3 stdlib, no build step)
tests/       smoke.sh: synthetic media, every script, positive and negative cases
docs/        recipes, TV support, case log
AGENTS.md    instructions for AI agents; CLAUDE.md imports it for Claude Code
```

## Changing the scripts

1. Keep the conventions: usage header (`-h`), exit codes 0/1/2, the markers above, `set -u` in bash, Python standard
   library only, run Python with `python3 -I`.
2. Add or update a case in `tests/smoke.sh`; run it and `bash -n` / `python3 -m py_compile` (and `shellcheck` if
   installed).
3. Update the Tools table here and the matching docs. After a real session, add an entry to `docs/case-log.md`.
