# AGENTS.md

Instructions for AI agents asked to make movie files play on the owner's Samsung TV, or to maintain this repo.
People can use it as a checklist too.

## Read first

1. This file.
2. [docs/recipes.md](docs/recipes.md): diagnosis, fixes, verification, swap-in, test clips, pitfalls.
3. [docs/case-log.md](docs/case-log.md): search it for a similar file (same codec, encoder, container, symptom) before
   inventing a new fix.
4. [docs/tv-support.md](docs/tv-support.md) when a limit matters, or when the TV is not the QE55QN80H.
5. `README.md` → "Tools" for every script's arguments, cost and exit codes. Every script also has `--help`.

Run `scripts/check_deps.sh` at the start. If a required tool is missing, **ask the owner to install it** (give the
`apt install` line from README.md); you have no sudo.

## Hard rules

These come from the owner's standing instructions. Don't break them, even to save time.

1. **Lossless only.** Remux with mkvtoolnix; ffmpeg only with `-c copy` (bitstream filters allowed: say that you used
   them). Never re-encode, never drop data silently.
2. **Ask before anything lossy or destructive.** That includes re-encoding (DTS/TrueHD, 10-bit H.264, VC-1, GMC ≥ 2,
   bitrate over the limit), converting ASS/SSA or PGS subtitles, dropping audio or subtitle tracks, labelling track
   languages you didn't get from the owner, and deleting anything (backups, work copies, test clips).
   Flag the problem, propose the least lossy option, and wait.
3. **Originals stay untouched** until a fix is verified: write outputs to a work folder on a fast local disk (`<work>`),
   never in place on the movie drive. `avi_fix_bih.py` edits in place: run it on a copy only.
4. **Keep backups** (`swap_in.sh` moves originals to a backup folder on the same drive) until the owner has confirmed
   TV playback. Delete backups and work copies only on the owner's explicit yes.
5. **Verification gate.** A fixed file may replace or join the originals only after:
   - `verify_remux.sh` printed `RESULT: VERIFIED` (exit 0), with `ALLOW_ADDED_SUBS=1` if subtitles were muxed in; and
   - every muxed-in subtitle track passed `srt_compare.py` / `tx3g_compare.py` (exit 0); and
   - the timestamps line is `[OK] frame timestamps identical` or `[NOTE] constant ...` (never a non-uniform offset).
   Report `[OK~]`, `[OK*]` and `[NOTE]` lines to the owner in plain words.
6. **You can't test on the TV.** Never say a file "will play" or "is fixed" before the owner has confirmed it.
   Say "verified lossless, not yet tried on the TV". If unsure what the TV accepts, build test clips
   (docs/recipes.md §5) and let the owner try them in one trip.
7. **Drive health first.** Check the kernel log before bulk I/O. On a drive with errors, copy each source to the SSD
   once and work from the copy; never run two full reads of the same HDD in parallel.
8. **Privacy and portability.** No personal names, user names, absolute paths or e-mail addresses in this repo; examples
   use the placeholders `<movies>`, `<work>`, `<backup>`, `<drive>` (defined at the top of docs/recipes.md).

## Workflow

1. **Ask for the symptom** if the owner gave none: which files fail, what the TV shows, which similar files play.
   A "playing vs failing" comparison is the most effective diagnostic (recipes §1.5).
2. **Inventory:** `scripts/inspect.sh "<movies>"`; read every `RED FLAG:` line.
3. **Deep checks** per candidate: `h264_sps_report.py` (H.264), `mpeg4_asp_check.sh` + `mpeg4_vol.py` +
   `avi_headers.py` (DivX/Xvid), `packet_scan.py --keep-csv` (full read: errors, bitrate peaks, drop frames).
4. **Pick the fix** from recipes §2. Look in the case log first. Test risky options on a 2-minute sample.
5. **Mux** into `<work>`. mkvmerge exit code 1 means warnings: read them.
6. **Verify** (rule 5). Run several files in parallel from the SSD (3–4 at a time).
7. **Deliver:** `swap_in.sh` for files on the drive, or a plain move/rename on the SSD when the owner asked for a
   separate output folder. When replacing your own earlier output: temp name → fsync → drop cache → `cmp` → rename.
8. **Report** (below), then **update the docs** (below).

### Interpreting results

| Output | Meaning | Action |
|---|---|---|
| `RESULT: VERIFIED` + `[OK] frame timestamps identical` | bit-exact remux, same timing | deliver |
| `[NOTE] constant frame-timestamp offset … +40 ms` (+42 ms at 23.976/24 fps) | native MPEG-4 remux of a B-frame AVI | expected; deliver |
| `[FAIL] frame timestamps differ non-uniformly` | drop frames dropped by native mode | `ts_v2_from_frames.py` → re-mux with `--timestamps 0:ts.txt` → verify again |
| `[OK~] … minus its LAST N bytes` | incomplete final audio frame dropped | harmless; mention it |
| `[FAIL] track list differs` | a track missing, reordered or changed | fix the mux, unless the change was intended (e.g. a dropped picture track): then explain it |
| `[WARN] I/O errors` / new kernel medium errors | the drive, not the file | stop bulk I/O, tell the owner, `badsector_map.sh` |
| `RED FLAG: … ASK USER` | needs lossy work | ask (hard rule 2) |

### Reporting to the owner

Keep it short and concrete:
- **cause** (or the best candidate, and what is still unknown);
- **what was changed** in each file;
- **verification evidence**: frames, timestamps, audio, subtitles;
- **where** the fixed files and the backups are;
- **what is not done or not verified**, starting with "not yet tried on the TV";
- **decisions the owner must make** (lossy options, deletions).

Use the owner's language. Don't paste raw logs.

## Maintaining this repo

- **Conventions** for every script:
  - a usage header shown by `-h`/`--help`;
  - exit codes 0 = OK, 1 = check failed / finding, 2 = usage error, missing tool or unreadable input;
  - one finding per line with the markers from README.md;
  - bash with `set -u`; Python standard library only, run as `python3 -I`;
  - no network access, no writes outside the paths given as arguments (except temp files).
- **Tests:** every new script or behaviour gets a case in `tests/smoke.sh`, positive and negative. Before finishing a
  change, run `tests/smoke.sh` (must end with `0 failed`), `bash -n scripts/*.sh tests/*.sh`,
  `python3 -m py_compile scripts/*.py` (then delete `scripts/__pycache__`), and `shellcheck` if installed.
- **Docs in sync:**
  - a script change updates README.md's Tools table and the affected recipe;
  - a new TV observation goes into docs/tv-support.md ("Observed on…", with its confidence);
  - every real session gets a docs/case-log.md entry: findings, fix, verification, the owner's playback report;
  - correct old advice that a later case disproved, and say which case disproved it.
- **Git:** commit only when the owner asks. Small, focused commits; the message says what changed and why.
  Never commit media files, logs or work folders (see `.gitignore`).
