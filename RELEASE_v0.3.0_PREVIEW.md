# OpenCode 1.18.27 for Android/Termux (aarch64) — v0.3.0 preview

## Summary

Upgrade from OpenCode **1.17.9/1.17.10** to **1.18.27**, with OpenTUI **0.4.5**
(`@opentui/core` v0.4.5, commit `0c8c4f7cff2927e3df63a9757a45eff9a343611c`).

This build carries forward all Android fixes from v0.2.x and targets the
upstream release that contains the hang-relevant fixes:

## Why 1.18.27 (hang-relevant upstream fixes)

- `4eb29a64f` — default SSE **chunk timeout 300 s**. Before: a provider stream
  that opened but sent nothing stalled forever (the "llm runtime selected →
  nothing" shape).
- `b04697366` — default **header timeout 300 s** (previously infinite for
  non-OpenAI providers).
- `c78986831` — **retry cap** (`RETRY_MAX_RETRIES=5`) + jitter; no more
  infinite "Thinking" retry loops.
- `b7f936339` — compaction serializes old attachments as
  `[Attached mime: filename]` placeholders instead of deep-cloning the whole
  message head with inline media (relevant to large screenshot-heavy sessions).

Open problems that remain upstream: Effect fiber lost-wakeup under memory
pressure (#35870), Bun TLS/event-loop deadlock family (#39977/#39859/#44782),
subagent permission hangs (#44747/#43996), large-session resume stalls
(#43277). Expect "fail visibly and retry" rather than "never fail" for the
network-stall family.

## What changed in the port

- OpenCode bumped to **1.18.27**; OpenTUI bumped **0.4.2 → 0.4.5**
- **Bun standalone on Android starts with an EMPTY `process.env`** (measured:
  0 keys; `os.homedir()` still works via bionic). Every env-gated patch
  silently never fired — including in the old 1.17.x builds. All Android
  behavior is now env-free:
  - `global.ts`: production layout from `os.homedir()` (`~/.local/share`,
    `~/.config`, `~/.local/state`, `~/.cache`, `tmp` nested under cache);
    `opencode-next` executables auto-detect and use `~/.opencode-next/*`
    (XDG_* variables cannot work and are ignored)
  - watcher/config/audio/spawn guards are unconditional (graph is
    Android-only)
  - `libopentui.so` resolves next to the running executable, then the
    Termux lib dir (no `OPENTUI_LIB_PATH`; it is unreadable on device)
- OpenCode source patches moved from inline perl to a real patch file:
  `patches/opencode/android-termux-1.18.patch`
  - Termux-safe cache/tmp paths (`packages/core/src/global.ts`)
  - file watcher disabled (`packages/core/src/filesystem/watcher.ts`, moved
    from `packages/opencode/src/file/watcher.ts`)
  - background npm dependency install skipped
    (`packages/opencode/src/config/config.ts`; 1.18.x now uses
    @npmcli/arborist in-process — the old BunProc patch is obsolete)
  - TUI audio disabled (`packages/tui/src/audio.ts`)
  - TUI startup diagnostics (`packages/tui/src/app.tsx`, moved from
    `packages/opencode/src/cli/cmd/tui/`)
  - negative-pid (process-group) kill avoided + `detached: false` on Android
    (`packages/core/src/cross-spawn-spawner.ts`, `packages/core/src/shell.ts`)
- OpenTUI 0.4.5: audio *stream* exports added upstream — all stubbed; new
  hard guard fails the build if any audio export is left unstubbed
- @opentui/core 0.4.5 JS: `index-*.js` became `chunk-bun-*.js`/`chunk-node-*.js`;
  FFI `toU32()` + `OPENTUI_LIB_PATH` patches updated for the new chunk layout
- Standalone bundling: `splitting: false` (host Bun 1.3.2 chunk-name collision
  with openai@6.39.1), tree-sitter worker embedded via `files:` +
  `OTUI_TREE_SITTER_WORKER_PATH` (mirrors upstream `script/build.ts`)
- `undici` module-graph patch obsolete in 1.18.x (bundler now emits a real
  `import from "undici"` resolved by Bun's built-in module)
- Web-UI embedding intentionally skipped (keeps module graph small)
- All v0.2.x runtime fixes preserved:
  - real filesystem `libopentui.so` via `OPENTUI_LIB_PATH`
  - bundled `libtagfix.so` and `libc++_shared.so`
  - TUI audio disabled
  - OpenTUI built with `ReleaseFast`, audio/span-feed guards, FFI `toU32()`

## Validation status

- Patch application verified against real opentui v0.4.5 and opencode
  v1.18.27 trees (`git apply --check` clean on both)
- `bun install --ignore-scripts` with host Bun 1.3.2: 4709 packages OK
- Full standalone build pipeline executed on x86_64 host: 170.2 MB binary,
  module graph 73 MB, trailer/offsets verified
- Device smoke (Android 15 + Android 12 5-prompt matrix) pending

## Install

**Termux (pacman):**
```bash
pacman -U opencode-1.18.27-1-aarch64.pkg.tar.xz
```

**Termux (dpkg):**
```bash
dpkg -i opencode_1.18.27_aarch64.deb
```

**Standalone (zip):**
```bash
unzip opencode-1.18.27-android-aarch64.zip -d $PREFIX/bin/
chmod +x $PREFIX/bin/opencode $PREFIX/bin/opencode.bin
```

## Build info

- Bun: v1.2.13 (cross-compiled for Android aarch64; host Bun 1.3.2 pinned)
- OpenCode: 1.18.27
- OpenTUI: 0.4.5 (`0c8c4f7cff2927e3df63a9757a45eff9a343611c`)
- WebKit/JSC: 017930ebf915121f8f593bef61cbbca82d78132d
- Android API level: 24
- NDK: r28b

## Release recommendation

- Publish as **pre-release** `v0.3.0-1.18.27-android-rc1` after the device
  smoke matrix passes
- Promote to **v0.3.0** final once both Android 12 and 15 are green
