# Upgrade Guide: 1.17.9 → 1.18.27 on Termux

How to install the **v0.3.0-1.18.27-android-rc1** build without risking your
working 1.17.9 setup, test it, and promote (or roll back).

> **Why upgrade:** upstream 1.18.27 contains the fixes most relevant to the
> "llm runtime selected → nothing, no request reaches provider" hang:
> 300 s SSE chunk/header timeouts (`4eb29a64f`, `b04697366`), a retry cap
> (`c78986831`), and attachment-placeholder compaction (`b7f936339`).
> Details: `RELEASE_v0.3.0_PREVIEW.md`.

---

## 0. What you need

- Termux on aarch64 (your current install, OpenCode 1.17.9, untouched)
- The release zip:
  `opencode-1.18.27-android-aarch64.zip` from
  https://github.com/Konaimav2/opencode-termux/releases/tag/v0.3.0-1.18.27-android-rc1
- ~600 MB free space (zip 485 MB + extracted ~170 MB; delete the zip after)

Download into Termux:

```bash
cd ~
curl -LO https://github.com/Konaimav2/opencode-termux/releases/download/v0.3.0-1.18.27-android-rc1/opencode-1.18.27-android-aarch64.zip
```

---

## 1. Side-by-side install (recommended first step)

This installs the new build as `opencode-next`. Your production `opencode`
1.17.9, its sessions, config, and auth are **never touched**.

```bash
mkdir -p ~/opencode-next && cd ~/opencode-next

# Zip contains: opencode (wrapper), opencode.bin (real ELF), and the .so libs
unzip -o ~/opencode-1.18.27-android-aarch64.zip

# Rename the real binary; drop the stock wrapper
mv opencode.bin opencode-next.bin
rm -f opencode opencode-debug opencode-debug.bin

# Install the opencode-next launcher (XDG-isolated clone of the stock wrapper)
curl -L https://raw.githubusercontent.com/Konaimav2/opencode-termux/upgrade/opencode-1.18.27/bin/opencode-next \
  -o opencode-next
chmod +x opencode-next opencode-next.bin

# Sanity check
./opencode-next --version     # expect: 1.18.27
opencode --version            # expect: 1.17.9 (production, unchanged)
```

### Data isolation

`opencode-next` redirects all OpenCode storage into `~/.opencode-next/`:

| Production (untouched)          | Test build                       |
|---------------------------------|----------------------------------|
| `~/.local/share/opencode`       | `~/.opencode-next/share/opencode`|
| `~/.config/opencode`            | `~/.opencode-next/config/opencode`|
| `~/.cache/opencode`             | `~/.opencode-next/cache/opencode`|
| `~/.local/state/opencode`       | `~/.opencode-next/state/opencode`|

To reuse your provider config and auth in the test build:

```bash
mkdir -p ~/.opencode-next/config/opencode ~/.opencode-next/share/opencode
cp ~/.config/opencode/opencode.json ~/.opencode-next/config/opencode/ 2>/dev/null || true
cp ~/.local/share/opencode/auth.json ~/.opencode-next/share/opencode/ 2>/dev/null || true
```

(Only do this if you want the same 9Router/provider setup; the DB and sessions
stay separate either way.)

---

## 2. Test matrix (run against `opencode-next`)

Run these in order; stop and report if any step hangs.

### Basic
```bash
~/opencode-next/opencode-next --version
~/opencode-next/opencode-next --help
cd ~/opencode-next && ~/opencode-next/opencode-next run "say hi"   # headless smoke
~/opencode-next/opencode-next                                       # TUI up, logo renders
```

### Tool loop (in TUI)
1. `run ls and summarize` — expect: model → bash tool → result → model summary
2. Repeat 3–5×. No stuck "Thinking".

### Permission
1. Ask for a command that triggers the permission prompt
2. Accept → turn continues to completion
3. New turn, trigger again → Reject → turn stops cleanly (no busy-loop)

### 9Router / providers
1. Send a GPT-5.6 Terra request; confirm it appears in the 9Router log
2. Optional stall test: block network briefly mid-request — the new build
   should **fail/retry at ~300 s** instead of hanging forever

### Vision + ADB workflow (the important one for you)
```bash
adb exec-out screencap -p > /data/data/com.termux/files/home/shot1.png
```
1. Attach `shot1.png` in TUI, ask the model to describe it
2. Ask a follow-up question about the image (tests continuation after vision)
3. Capture + attach 3–4 more screenshots across turns
4. Check test-profile growth: `du -sh ~/.opencode-next/share/opencode`

### Session continuity
1. Fresh session works (already covered above)
2. Exit, `~/opencode-next/opencode-next` → resume the small session (TUI: pick
   session from history)
3. Multi-turn tool session → exit → resume

### APK workflow end-to-end
In the test build, inside your APK project:
edit a file → gradle build → `adb install` → launch → `logcat` inspection →
screenshot → vision analysis → continue coding.

### Old-build comparison (optional but valuable)
The known hang was reproducible by resuming the large vision-heavy session.
Production sessions are NOT visible to the test build (isolated). To compare
fairly, snapshot a **copy** of the production database into the test profile
(never move the original — 1.18.x runs migrations on first open):

```bash
rm -f ~/.opencode-next/share/opencode/opencode.db*
python3 -c 'import sqlite3; c=sqlite3.connect("/data/data/com.termux/files/home/.local/share/opencode/opencode.db"); c.execute("vacuum into \x27/data/data/com.termux/files/home/.opencode-next/share/opencode/opencode.db\x27")'
```
Then resume that session in `opencode-next` (`run -s <SESSION_ID>` or the
TUI history picker). If it hangs the same way, capture
`~/.opencode-next/share/opencode/log/opencode.log` before killing it.

---

## 3. Promote to production (only after tests pass)

The v1 session format did not change between 1.17.9 and 1.18.27, so your
existing data upgrades in place:

```bash
# pacman-based Termux:
pacman -U ~/opencode-1.18.27-1-aarch64.pkg.tar.xz

# dpkg-based Termux:
dpkg -i ~/opencode_1.18.27_aarch64.deb
```

Then verify: `opencode --version` → `1.18.27`, and your old sessions still
appear in the TUI.

Keep `~/opencode-next/` around until you're confident; it's harmless.

## 4. Rollback

| Situation | Action |
|---|---|
| Test build misbehaves | `rm -rf ~/opencode-next ~/.opencode-next` — production was never touched |
| Upgraded via pacman/deb, need old version | reinstall the 1.17.9 artifact from the previous release (`pacman -U` / `dpkg -i`); v1 session data is backward-compatible |
| Want a debug binary for a crash | the zip's debug variant was removed in step 1 — re-extract the zip elsewhere and keep `opencode-debug` + `opencode-debug.bin`, then run it the same way as `opencode-next` |

## 5. Notes & known limitations (unchanged from 1.17.x builds)

- File watcher disabled on Android (falls back gracefully)
- TUI audio disabled (native audio stubbed)
- `bun upgrade` disabled — update by installing new release packages
- **`process.env` is empty inside Bun standalone on Android** (measured: 0
  keys). Consequences:
  - Provider API keys from shell env vars are invisible — use `auth.json`
    or inline `apiKey` in `opencode.json` instead
  - All Android behavior in this build is env-free by design (paths resolve
    from `os.homedir()` + executable location)
  - This also affects the old 1.17.x builds: any `TERMUX_*`-gated behavior
    there silently never fired
- **ripgrep auto-install is broken on Android**: OpenCode downloads an
  x86-64 Linux `rg` into its bin cache at runtime (`ENOEXEC` on `@file`
  mentions / glob). Workaround (test profile shown; production analogous):
  ```bash
  rm -f ~/.opencode-next/cache/opencode/bin/rg
  ln -s $PREFIX/bin/rg ~/.opencode-next/cache/opencode/bin/rg
  ```
- Still-open upstream issues: Effect fiber lost-wakeup (#35870), Bun TLS
  event-loop deadlocks (#39977 family), subagent permission hangs (#44747).
  The upgrade converts "hang forever" into "error + retry" for the
  network-stall family; other families may still stall — capture logs and
  file against the fork if you hit them.

## 6. On-device test results (v0.3.0-1.18.27-android-rc3, Android 15)

All headless tests passed on 2026-09-05 (production 1.17.9 untouched):

| Test | Result |
|---|---|
| `--version` | `1.18.27` |
| isolated dirs (`~/.opencode-next/*`, zero `/tmp` refs, strace-verified) | pass |
| simple text request (9Router/Free) | pass |
| tool loop (model → bash → result → summary) | pass |
| session resume (`--continue`) | pass |
| `gpt-5.6-terra` text request | pass |
| `gpt-5.6-terra` + tool continuation (the hang signature) | pass |
| vision: 2.1 MB ADB screenshot → `@` attach → analysis | pass |
| giant session resume (31.6 MiB, 3353 parts, 811K tokens, 808K cached) | **pass — loop completes, model replied correctly** (was: infinite hang on 1.17.9). Note: 1–3 attempts via retry machinery, ~1–8 min; see hang-analysis below |
| TUI interactive boot + render | **pass on rc4** (logo, prompt, model selector, version; verified via pty capture). Interactive prompt/permission flow | **not tested — please verify** |

### Hang root-cause analysis (evidence from this investigation)

Verdict: **H — interaction of several causes** (no single bug):

- **F. Inline image history (high confidence).** `toModelMessages` is
  byte-identical in 1.17.9 and 1.18.27: every historical user-attached
  image is re-emitted with its full `data:` URL on *every* turn, with no
  pruning until compaction truncates history. Verified 40 images /
  25.87 MiB in `ses_fa531f5c8ffeW0F9zxs4jWnS2E`.
- **G. Session resume/history processing (high).** Resume/fork/raw-glob of
  the old session reproduces; fresh sessions work. Cost is full-history
  conversion per turn.
- **A. OpenCode 1.17.9 (high, contributory).** No chunk/header timeouts
  (fixes `4eb29a64f`/`b04697366` exist only in ≥1.18.26, verified via
  `git tag --contains`) and a heavier compaction path
  (`structuredClone` + 2× `toModelMessages(stripMedia)` over the full
  media head vs 1.18.27's O(text) `serialize()`). A stall that 1.18.27
  bounds and retries through becomes infinite on 1.17.9.
- **B. Newer OpenCode fixes the infinite hang (medium-high).** 3/3 giant
  loop completions, working retries (`stream error` → retry → success
  observed in logs), graded ladder 1–25 MiB all pass with flat RSS
  (555–641 MB). NOT a complete fix: on 31 MB sessions the headless
  process sometimes lingers after loop exit (idle threads, no log) and
  responses are occasionally empty — narrower, still open.
- **D. JSC GC/memory (medium).** 870 MB peak RSS on giant runs (both
  versions); HeapHelper/Collector threads observed; RSS declines after
  peak (GC working, not leaking). Amplifier, not sole cause.
- **C. Android Bun (medium).** Measured: Bun standalone starts with
  **zero** `process.env` keys (breaks all env-gated behavior, incl. in
  1.17.x); host Bun 1.3.2 bundler needed 4 workarounds (Undici namespace,
  worker-asset eager init, chunk splitter, tree-sitter embedding).
  Runtime scheduling under NDK/JSC remains a suspect for the exact stall
  point, unproven.
- **E. AI SDK serialization (medium).** 31 MB payloads serialize + upload
  per attempt (68 s–8 min observed); retries multiply cost; one
  `AI_APICallError: <none>` + empty responses suggest provider-side
  strain on huge payloads too.
- **OpenTUI: no evidence.** Hangs reproduce headless; TUI renders fine.

## 6. Building newer versions yourself

Fork CI is wired for GitHub-hosted runners:

**Actions → Build OpenCode for Android/Termux → Run workflow**
- branch: `upgrade/opencode-1.18.27`
- `opencode_version`: the tag to build (e.g. `1.18.28`)
- `runner`: `ubuntu-latest` (free, ~55 min) or `self-hosted` if you attach one
- `create_prerelease`: ✔, set `release_tag` (e.g. `v0.3.1-1.18.28-android-rc1`)

The OpenTUI/OpenCode patch files live in `patches/` — if a future OpenCode
release moves files again, regenerate
`patches/opencode/android-termux-1.18.patch` against the new tag (the build
fails loudly rather than silently mis-patching).
