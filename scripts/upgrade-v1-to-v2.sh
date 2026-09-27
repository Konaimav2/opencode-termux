#!/usr/bin/env bash
# upgrade-v1-to-v2.sh - Replace-mode V1 (1.18.27) -> V2 upgrade via ~/opencode-next test slot.
# Fork: Konaimav2/opencode-termux. On-device Termux bash (requires bash: pipefail/PIPESTATUS).
# Needs: curl unzip python3, plus dpkg and/or pacman for --promote.
# Decisions: (1) V2 Latest resolved at runtime, (2) no NDK/build, (3) Replace mode reuses
# ~/opencode-next + ~/.opencode-next/* test slot, (4) auto-migration only (first V2 start
# creates ~/.config/opencode/cli.json from tui.json, no native-V2 rewrite).
# Style: bin/opencode:1 wrapper resolution, UPGRADE.md side-by-side table,
# scripts/smoke-android-package.sh layout checks.
set -euo pipefail
REPO="Konaimav2/opencode-termux"
DRY_RUN=0
DO_YES=0
DO_PROMOTE=0
KEEP_BACKUP=0
TEST_LIVE=0
REF="latest"
TS="$(date +%Y%m%d-%H%M%S)"
HOME_DIR="${HOME:-/data/data/com.termux/files/home}"
SCRATCH="${HOME_DIR}/tmp"
# --help must stay side-effect-free: answer before creating any dirs/logs.
for _a in "$@"; do
  case "$_a" in --help|-h)
    cat <<'HELP'
Usage: upgrade-v1-to-v2.sh [--dry-run] [--yes] [--promote] [--test-live-model] [--ref REV] [--keep-backup] [--help]
  --help            Show this help + rollback guide (no side effects).
  --dry-run         Print planned actions only; change nothing (safe without --yes).
  --yes             REQUIRED for destructive replace (rm -rf ~/opencode-next ~/.opencode-next).
  --promote         After test-slot verify passes, install .deb/.pkg.tar.xz to production.
                    Default OFF: without it, stop after test-slot verify.
  --test-live-model Also run a live model smoke (opencode-next run "say hi", costs tokens).
                    Default OFF: verify is local-only (--version + --help).
  --ref REV         Release tag to use (default: latest = resolve at runtime via GitHub API).
  --keep-backup     Disable pruning of backups older than 14 days (prune runs only with
                    --yes and never touches the current backup).
Isolation (UPGRADE.md side-by-side):
  production: ~/.local/share/opencode | ~/.config/opencode | ~/.cache/opencode | ~/.local/state/opencode
  test slot:  ~/.opencode-next/share  | ~/.opencode-next/config | ~/.opencode-next/cache | ~/.opencode-next/state
  Production opencode 1.x configs are only READ for backup until --promote.
Rollback:
  test misbehaves : rm -rf ~/opencode-next ~/.opencode-next   (production untouched)
  promoted, need V1: reinstall the prior V1 artifact from the previous GitHub
      release (the backup dir stores v1-version.txt for reference, not the
      package itself):
      dpkg -i ~/opencode_1.18.27_aarch64.deb
      # or: pacman -U ~/opencode-1.18.27-1-aarch64.pkg.tar.xz
    then restore configs/db snapshot from ~/opencode-backup-v1-<TS>/
      (see MANIFEST.txt; chmod 0600 ~/.local/share/opencode/auth.json after restore),
    and abort the test slot: rm -rf ~/opencode-next ~/.opencode-next
HELP
    exit 0 ;;
  esac
done
umask 077
LOGDIR="${HOME_DIR}/.opencode-next/logs"
mkdir -p "$SCRATCH" 2>/dev/null || true
mkdir -p "$LOGDIR" 2>/dev/null || LOGDIR="$HOME_DIR"
LOGFILE="${LOGDIR}/upgrade-${TS}.log"
if [ ! -d "$LOGDIR" ] || [ ! -w "$LOGDIR" ]; then LOGDIR="$HOME_DIR"; LOGFILE="${HOME_DIR}/opencode-upgrade-${TS}.log"; fi
: > "$LOGFILE" 2>/dev/null || LOGFILE="/dev/stdout"
V1_PIN=""
BACKUP_DIR="${HOME_DIR}/opencode-backup-v1-${TS}"
VERIFY_PASS=0
log(){ printf '[%s] [%s] %s\n' "$(date +%H:%M:%S)" "$1" "$(printf '%s' "$2" | redact)" | tee -a "$LOGFILE"; }
step(){ log "STEP" "$1"; }
result(){ log "RESULT" "$1"; }
bug(){ log "BUG" "$1"; }
redact(){ sed -E -e 's/eyJ[A-Za-z0-9_.-]{10,}[A-Za-z0-9_.-]*/<redacted-jwt>/g' -e 's/sk-[A-Za-z0-9_-]{10,}/<redacted>/g' -e 's/gh[pousr]_[A-Za-z0-9_]{10,}/<redacted>/g' -e 's/github_pat_[A-Za-z0-9_]{10,}/<redacted>/g' -e 's/(Bearer[ :]*)[A-Za-z0-9_.-]+/\1<redacted>/gi' -e 's/((api[_-]?key|token|secret|password)["'"'"'=: ]+)[^"'"'"' ]+/\1<redacted>/gi'; }
usage(){
cat <<'HELP'
Usage: upgrade-v1-to-v2.sh [--dry-run] [--yes] [--promote] [--test-live-model] [--ref REV] [--keep-backup] [--help]
  --help            Show this help + rollback guide.
  --dry-run         Print planned actions only; change nothing (safe without --yes).
  --yes             REQUIRED for destructive replace (rm -rf ~/opencode-next ~/.opencode-next).
  --promote         After test-slot verify passes, install .deb/.pkg.tar.xz to production.
                    Default OFF: without it, stop after test-slot verify.
  --test-live-model Also run a live model smoke (costs tokens). Default OFF.
  --ref REV         Release tag to use (default: latest = resolve at runtime via GitHub API).
  --keep-backup     Disable pruning of backups older than 14 days (prune runs only with
                    --yes and never touches the current backup).
Isolation (UPGRADE.md side-by-side):
  production: ~/.local/share/opencode | ~/.config/opencode | ~/.cache/opencode | ~/.local/state/opencode
  test slot:  ~/.opencode-next/share  | ~/.opencode-next/config | ~/.opencode-next/cache | ~/.opencode-next/state
  Production opencode 1.x configs are only READ for backup until --promote.
Rollback:
  test misbehaves : rm -rf ~/opencode-next ~/.opencode-next   (production untouched)
  promoted, need V1: reinstall the prior V1 artifact from the previous GitHub
      release (the backup dir stores v1-version.txt for reference, not the
      package itself):
      dpkg -i ~/opencode_1.18.27_aarch64.deb
      # or: pacman -U ~/opencode-1.18.27-1-aarch64.pkg.tar.xz
    then restore configs/db snapshot from ~/opencode-backup-v1-<TS>/
      (see MANIFEST.txt; chmod 0600 ~/.local/share/opencode/auth.json after restore),
    and abort the test slot: rm -rf ~/opencode-next ~/.opencode-next
  Full log path is printed at exit. WARNING: inspecting opencode.json/auth.json
  on screen may expose secrets; do not paste them into chats/logs.
HELP
}
while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --yes) DO_YES=1; shift ;;
    --promote) DO_PROMOTE=1; shift ;;
    --test-live-model) TEST_LIVE=1; shift ;;
    --keep-backup) KEEP_BACKUP=1; shift ;;
    --ref) REF="${2:?--ref needs a value}"; shift 2 ;;
    --ref=*) REF="${1#--ref=}"; shift ;;
    *) echo "unknown flag: $1 (see --help)" >&2; exit 2 ;;
  esac
done
fail(){ echo "ABORT: $1" | redact | tee -a "$LOGFILE" >&2; echo "Log: $LOGFILE" >&2; exit 1; }
step "preflight: arch=$(uname -m 2>/dev/null || echo ?) PREFIX=${PREFIX:-unset}"
WARN=0
M="$(uname -m)"
if [ "$M" != "aarch64" ]; then
  if [ "$DRY_RUN" -eq 1 ] || [ -z "${PREFIX:-}" ]; then log "RESULT" "WARN: not aarch64 ($M); continuing (dry-run/dev host)"; WARN=1;
  else fail "need aarch64 Termux (uname -m=$M)"; fi
fi
if [ -z "${PREFIX:-}" ]; then
  if [ "$DRY_RUN" -eq 1 ]; then log "RESULT" "WARN: \$PREFIX unset (not Termux); continuing dry-run"; WARN=1;
  else fail "not Termux: \$PREFIX is unset"; fi
fi
for t in curl unzip python3; do
  command -v "$t" >/dev/null 2>&1 || fail "missing tool: $t (pkg install $t)";
done
FREE_KB="$(df -k "$HOME_DIR" 2>/dev/null | awk 'NR==2{print $4}')"
if [ -n "$FREE_KB" ] && [ "$FREE_KB" -lt 614400 ]; then fail "disk <600MB free (${FREE_KB}KB)"; fi
result "disk ok (${FREE_KB:-?}KB free)"
V1_PIN="$(opencode --version 2>/dev/null | head -n1 || echo unknown)"
result "V1 pin: $V1_PIN"
printf 'V1_PIN=%s\nDATE=%s\nREF=%s\n' "$V1_PIN" "$TS" "$REF" >> "$LOGFILE"
if [ "$DRY_RUN" -eq 1 ]; then
  log "STEP" "[dry-run] would backup to $BACKUP_DIR (opencode.json/tui.json/auth.json 0600/db snapshot via vacuum-into, .opencode file list, cli.json if any; 0700 dir)"
  log "STEP" "[dry-run] would resolve ${REF} via api.github.com/repos/${REPO}/releases, pick zip+deb+pkg assets (+SHA256SUMS best-effort)"
  log "STEP" "[dry-run] would download zip to ~ (keep for rollback), size>10MB, unzip -l lists opencode+opencode.bin+.so"
  log "STEP" "[dry-run] would need --yes then: rm -rf ~/opencode-next ~/.opencode-next; unzip -o; rename opencode.bin->opencode-next.bin; install opencode-next wrapper (XDG->~/.opencode-next/*, LD_PRELOAD libtagfix, BUN_SELF_EXE)"
  log "STEP" "[dry-run] would copy opencode.json+auth.json (0600) into test profile (never move), verify local-only: --version (2.x), --help, cli.json auto-migration note, rg symlink note (live model smoke only with --test-live-model)"
  log "STEP" "[dry-run] WARN: V1 plugins do NOT run on V2; server API callers must be ported (no auto-port)"
  if [ "$DO_PROMOTE" -eq 1 ]; then log "STEP" "[dry-run] would promote: pacman -U or dpkg -i downloaded package, then opencode --version";
  else log "STEP" "[dry-run] default stop: no promote (re-run with --promote after verify)"; fi
  usage; echo "Log: $LOGFILE"; exit 0
fi
step "backup -> $BACKUP_DIR"
mkdir -p "$BACKUP_DIR"
chmod 0700 "$BACKUP_DIR"
N=0
[ -f "$HOME_DIR/.config/opencode/opencode.json" ] && cp "$HOME_DIR/.config/opencode/opencode.json" "$BACKUP_DIR/" && N=$((N+1))
[ -f "$HOME_DIR/.config/opencode/tui.json" ] && cp "$HOME_DIR/.config/opencode/tui.json" "$BACKUP_DIR/" && N=$((N+1))
[ -f "$HOME_DIR/.config/opencode/cli.json" ] && cp "$HOME_DIR/.config/opencode/cli.json" "$BACKUP_DIR/cli.json.v2existing" && N=$((N+1))
if [ -f "$HOME_DIR/.local/share/opencode/auth.json" ]; then cp "$HOME_DIR/.local/share/opencode/auth.json" "$BACKUP_DIR/" && chmod 0600 "$BACKUP_DIR/auth.json" && N=$((N+1)); fi
printf '%s\n' "$V1_PIN" > "$BACKUP_DIR/v1-version.txt"
{ dpkg -l opencode 2>/dev/null || true; pacman -Q opencode 2>/dev/null || true; } > "$BACKUP_DIR/v1-pkg-status.txt" 2>/dev/null || true
if [ -f "$HOME_DIR/.local/share/opencode/opencode.db" ]; then
  python3 - "$HOME_DIR/.local/share/opencode/opencode.db" "$BACKUP_DIR/opencode.db.snapshot" <<'PY'
import sqlite3,sys
src,dst=sys.argv[1],sys.argv[2]
c=sqlite3.connect(src); c.execute("vacuum into '"+dst.replace("'","''")+"'"); c.close()
PY
  N=$((N+1))
fi
for f in "$HOME_DIR/.local/share/opencode/opencode.db-wal" "$HOME_DIR/.local/share/opencode/opencode.db-shm"; do
  [ -f "$f" ] && cp "$f" "$BACKUP_DIR/" && N=$((N+1))
done
if [ -d .opencode ]; then find .opencode -type f | head -n 200 > "$BACKUP_DIR/opencode-project-files.txt"; N=$((N+1)); else echo "(no .opencode/ in cwd)" > "$BACKUP_DIR/opencode-project-files.txt"; fi
ls -la "$BACKUP_DIR" > "$BACKUP_DIR/MANIFEST.txt" 2>&1
[ "$N" -ge 2 ] || fail "backup incomplete (only $N items); aborting"
result "backup ok ($N items) -> $BACKUP_DIR (see MANIFEST.txt; filenames/counts only, no secrets)"
step "resolve release ref=$REF"
if [ "$REF" = "latest" ]; then API="https://api.github.com/repos/${REPO}/releases/latest";
else API="https://api.github.com/repos/${REPO}/releases/tags/${REF}"; fi
JSON="$SCRATCH/opencode-rel-${TS}.json"
curl -fsSL "$API" -o "$JSON" || fail "GitHub API failed ($API). If no V2 Android asset is published yet, CI must publish first."
TAG="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("tag_name",""))' "$JSON")"
[ -n "$TAG" ] || fail "could not parse tag_name from release JSON"
ZIP_URL="$(python3 -c 'import json,sys; a=json.load(open(sys.argv[1])).get("assets",[]); print("\n".join(x.get("browser_download_url","") for x in a))' "$JSON" | grep -E 'opencode-.*-android-aarch64\.zip$' | head -n1 || true)"
DEB_URL="$(python3 -c 'import json,sys; a=json.load(open(sys.argv[1])).get("assets",[]); print("\n".join(x.get("browser_download_url","") for x in a))' "$JSON" | grep -E 'opencode_.*_aarch64\.deb$' | head -n1 || true)"
PKG_URL="$(python3 -c 'import json,sys; a=json.load(open(sys.argv[1])).get("assets",[]); print("\n".join(x.get("browser_download_url","") for x in a))' "$JSON" | grep -E 'opencode-.*-aarch64\.pkg\.tar\.xz$' | head -n1 || true)"
[ -n "$ZIP_URL" ] || fail "no V2 Android zip asset in $TAG yet (CI must publish first). Assets seen: $(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("assets",[])))' "$JSON")"
result "tag=$TAG zip=$(basename "$ZIP_URL")"
step "download (keep zip for rollback)"
ZIPFILE="${HOME_DIR}/$(basename "$ZIP_URL")"
DEBFILE=""; PKGFILE=""
[ -n "$DEB_URL" ] && DEBFILE="${HOME_DIR}/$(basename "$DEB_URL")"
[ -n "$PKG_URL" ] && PKGFILE="${HOME_DIR}/$(basename "$PKG_URL")"
[ -f "$ZIPFILE" ] || curl -fSL "$ZIP_URL" -o "$ZIPFILE" || fail "zip download failed"
SZ="$(wc -c < "$ZIPFILE" | tr -d ' ')"
[ "$SZ" -gt 10485760 ] || { rm -f "$ZIPFILE"; fail "zip too small (${SZ}B); expected >10MB (removed, re-run to re-download)"; }
unzip -l "$ZIPFILE" 2>/dev/null | redact > "$SCRATCH/ziplist-${TS}.txt"
grep -q 'opencode$' "$SCRATCH/ziplist-${TS}.txt" || fail "zip missing wrapper 'opencode'"
grep -q 'opencode\.bin' "$SCRATCH/ziplist-${TS}.txt" || fail "zip missing opencode.bin"
grep -q '\.so' "$SCRATCH/ziplist-${TS}.txt" || fail "zip missing .so libs"
cat "$SCRATCH/ziplist-${TS}.txt" >> "$LOGFILE"
result "zip ok (${SZ}B) -> $ZIPFILE"
SUM_URL="$(python3 -c 'import json,sys; a=json.load(open(sys.argv[1])).get("assets",[]); print("\n".join(x.get("browser_download_url","") for x in a))' "$JSON" | grep -E 'SHA256SUMS|sha256sums' | head -n1 || true)"
if [ -n "$SUM_URL" ]; then
  if curl -fsSL "$SUM_URL" -o "$SCRATCH/SHA256SUMS-${TS}.txt" 2>/dev/null && [ -f "$ZIPFILE" ]; then
    ( cd "$HOME_DIR" && sha256sum -c --status -- "$SCRATCH/SHA256SUMS-${TS}.txt" 2>/dev/null ) && result "sha256 ok (SUMS asset)" || log "RESULT" "WARN: SHA256SUMS present but verify did not pass; continuing (size+contents checked)"
  fi
else log "RESULT" "NOTE: no SHA256SUMS asset in $TAG; verified by size+contents only"; fi
[ -z "$DEB_URL" ] || { [ -f "$DEBFILE" ] || curl -fSL "$DEB_URL" -o "$DEBFILE" || log "RESULT" "WARN: deb download failed, promote-via-deb unavailable"; }
[ -z "$PKG_URL" ] || { [ -f "$PKGFILE" ] || curl -fSL "$PKG_URL" -o "$PKGFILE" || log "RESULT" "WARN: pkg download failed, promote-via-pacman unavailable"; }
cp "$ZIPFILE" "$BACKUP_DIR/" 2>/dev/null || true
[ "$DO_YES" -eq 1 ] || { echo "Destructive replace needs --yes. Re-run with --yes [--promote] [--ref REV]. Backup already saved at $BACKUP_DIR. Log: $LOGFILE" >&2; exit 3; }
step "replace test slot ~/opencode-next + ~/.opencode-next (production untouched)"
ls -la "$BACKUP_DIR" >> "$LOGFILE" 2>&1
rm -rf "$HOME_DIR/opencode-next" "$HOME_DIR/.opencode-next"
mkdir -p "$HOME_DIR/opencode-next" "$HOME_DIR/.opencode-next/share" "$HOME_DIR/.opencode-next/config" "$HOME_DIR/.opencode-next/cache" "$HOME_DIR/.opencode-next/state" "$HOME_DIR/.opencode-next/logs"
chmod 0700 "$HOME_DIR/.opencode-next"
unzip -o "$ZIPFILE" -d "$HOME_DIR/opencode-next" > "$SCRATCH/unzip-${TS}.txt" 2>&1; tail -n 5 "$SCRATCH/unzip-${TS}.txt" | redact >> "$LOGFILE" 2>&1
[ -f "$HOME_DIR/opencode-next/opencode.bin" ] || fail "extract missing opencode.bin"
mv -f "$HOME_DIR/opencode-next/opencode.bin" "$HOME_DIR/opencode-next/opencode-next.bin"
rm -f "$HOME_DIR/opencode-next/opencode" "$HOME_DIR/opencode-next/opencode-debug" "$HOME_DIR/opencode-next/opencode-debug.bin"
RAW="https://raw.githubusercontent.com/${REPO}/${TAG}/bin/opencode-next"
if ! curl -fSL "$RAW" -o "$HOME_DIR/opencode-next/opencode-next"; then
  bug "curl wrapper failed ($RAW); generating minimal inline wrapper"
  cat > "$HOME_DIR/opencode-next/opencode-next" <<'WRAP'
#!/data/data/com.termux/files/usr/bin/sh
# opencode-next fallback wrapper (same isolation as bin/opencode-next).
set -e
dir="$(cd "$(dirname "$0")" && pwd)"
export ANDROID_ROOT="${ANDROID_ROOT:-/system}"
export TERMUX_VERSION="${TERMUX_VERSION:-opencode-termux}"
export TMPDIR="${OPENCODE_TMPDIR:-${HOME:-/data/data/com.termux/files/home}/.opencode-next/tmp}"
export TEMP="$TMPDIR"; export TMP="$TMPDIR"
export OPENCODE_DISABLE_TUI_AUDIO="${OPENCODE_DISABLE_TUI_AUDIO:-1}"
for d in "$HOME/.opencode-next/share" "$HOME/.opencode-next/config" "$HOME/.opencode-next/cache" "$HOME/.opencode-next/state" "$TMPDIR"; do mkdir -p "$d" 2>/dev/null || true; done
export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.opencode-next/share}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.opencode-next/config}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.opencode-next/cache}"
export XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.opencode-next/state}"
NATIVE_LIB_DIR=""
for candidate in "$dir/../lib" "$dir"; do if [ -f "$candidate/libtagfix.so" ]; then NATIVE_LIB_DIR="$candidate"; break; fi; done
if [ -n "$NATIVE_LIB_DIR" ]; then
  export LD_PRELOAD="${NATIVE_LIB_DIR}/libtagfix.so${LD_PRELOAD:+:$LD_PRELOAD}"
  export LD_LIBRARY_PATH="${NATIVE_LIB_DIR}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  export OPENTUI_LIB_PATH="${NATIVE_LIB_DIR}/libopentui.so"
  [ -f "${NATIVE_LIB_DIR}/librust_pty_arm64.so" ] && export BUN_PTY_LIB="${NATIVE_LIB_DIR}/librust_pty_arm64.so"
  export OPENCODE_EXPERIMENTAL_DISABLE_FILEWATCHER="${OPENCODE_EXPERIMENTAL_DISABLE_FILEWATCHER:-true}"
  [ -x "$NATIVE_LIB_DIR/bun" ] && export OPENCODE_BUN_PATH="$NATIVE_LIB_DIR/bun"
else echo "opencode-next: warning: native library directory not found" >&2; fi
for candidate in "$dir/opencode-next.bin" "$dir/../libexec/opencode/opencode-next.bin"; do
  if [ -x "$candidate" ]; then export BUN_SELF_EXE="$candidate"; exec "$candidate" "$@"; fi
done
echo "opencode-next: error: could not find opencode-next.bin" >&2; exit 127
WRAP
fi
chmod +x "$HOME_DIR/opencode-next/opencode-next" "$HOME_DIR/opencode-next/opencode-next.bin"
grep -q 'opencode-next.bin' "$HOME_DIR/opencode-next/opencode-next" || fail "wrapper is not the opencode-next launcher"
grep -q '\.opencode-next' "$HOME_DIR/opencode-next/opencode-next" || fail "wrapper lacks XDG isolation"
result "test slot installed"
mkdir -p "$HOME_DIR/.opencode-next/config/opencode" "$HOME_DIR/.opencode-next/share/opencode"
chmod 0700 "$HOME_DIR/.opencode-next"
[ -f "$HOME_DIR/.config/opencode/opencode.json" ] && cp "$HOME_DIR/.config/opencode/opencode.json" "$HOME_DIR/.opencode-next/config/opencode/" || true
if [ -f "$HOME_DIR/.local/share/opencode/auth.json" ]; then cp "$HOME_DIR/.local/share/opencode/auth.json" "$HOME_DIR/.opencode-next/share/opencode/" && chmod 0600 "$HOME_DIR/.opencode-next/share/opencode/auth.json" || true; fi
result "config copied (originals untouched)"
NEXT="$HOME_DIR/opencode-next/opencode-next"
step "verify test slot (local-only; no network/billing)"
"$NEXT" --version > "$SCRATCH/ver-${TS}.txt" 2>&1; RC=$?; redact < "$SCRATCH/ver-${TS}.txt" >> "$LOGFILE" 2>&1; tail -n 5 "$SCRATCH/ver-${TS}.txt" | redact || true
[ "$RC" -eq 0 ] || fail "opencode-next --version failed (rc=$RC)"
VER="$(head -n1 "$SCRATCH/ver-${TS}.txt" || echo unknown)"
case "$VER" in 2.*) result "version ok: $VER";; *) fail "expected 2.x, got: $VER";; esac
"$NEXT" --help > "$SCRATCH/help-${TS}.txt" 2>&1 || fail "opencode-next --help failed"; redact < "$SCRATCH/help-${TS}.txt" >> "$LOGFILE" 2>&1; tail -n 10 "$SCRATCH/help-${TS}.txt" | redact || true
if [ "$TEST_LIVE" -eq 1 ]; then
  step "live model smoke (opt-in, costs tokens)"
  if command -v timeout >/dev/null 2>&1; then timeout 120 "$NEXT" run "say hi" > "$SCRATCH/live-${TS}.txt" 2>&1; RC=$?;
  else "$NEXT" run "say hi" > "$SCRATCH/live-${TS}.txt" 2>&1; RC=$?; fi
  redact < "$SCRATCH/live-${TS}.txt" >> "$LOGFILE" 2>&1; tail -n 20 "$SCRATCH/live-${TS}.txt" | redact || true
  [ "$RC" -eq 0 ] || fail "headless run failed (rc=$RC). Log: $LOGFILE"
else
  result "live model smoke skipped (re-run with --test-live-model to spend tokens)"
fi
if [ -f "$HOME_DIR/.opencode-next/config/opencode/cli.json" ]; then result "auto-migration: test-profile cli.json present";
elif [ -f "$HOME_DIR/.config/opencode/cli.json" ]; then result "auto-migration: production cli.json present (first V2 start migrates tui.json)";
else log "RESULT" "NOTE: no cli.json yet; first V2 start auto-creates ~/.config/opencode/cli.json from tui.json"; fi
RGDIR=""; for c in "$HOME_DIR/.opencode-next/cache/opencode/bin" "$HOME_DIR/.opencode-next/cache/bin"; do [ -d "$c" ] && RGDIR="$c"; done
if [ -n "$RGDIR" ] && [ ! -x "$RGDIR/rg" ] && command -v rg >/dev/null 2>&1; then
  mkdir -p "$RGDIR"; ln -sf "$(command -v rg)" "$RGDIR/rg"; result "rg symlink workaround applied";
else log "RESULT" "rg note: system rg symlink workaround if @file mentions fail with ENOEXEC (UPGRADE.md s5)"; fi
VERIFY_PASS=1
result "test-slot verify PASS"
echo "WARN: V1 plugins do NOT run on V2; server API callers must be ported. Checklist (no auto-port):"
echo "  1) list plugins: ls ~/.config/opencode/plugin 2>/dev/null (do NOT cat auth.json/opencode.json to chat)"
echo "  2) check each plugin README for a V2-compatible release; reinstall per-V2 docs"
echo "  3) port scripts calling the opencode server API to the V2 CLI/API surface; re-run headless 'run' smoke per caller"
if [ "$DO_PROMOTE" -eq 1 ]; then
  [ "$VERIFY_PASS" -eq 1 ] || fail "refusing promote: verify did not pass"
  step "promote to production"
  INST=""
  if command -v pacman >/dev/null 2>&1 && [ -n "$PKGFILE" ] && [ -f "$PKGFILE" ]; then INST="pacman -U $PKGFILE";
  elif command -v dpkg >/dev/null 2>&1 && [ -n "$DEBFILE" ] && [ -f "$DEBFILE" ]; then INST="dpkg -i $DEBFILE";
  elif [ -n "$PKGFILE" ] && [ -f "$PKGFILE" ]; then INST="pacman -U $PKGFILE";
  elif [ -n "$DEBFILE" ] && [ -f "$DEBFILE" ]; then INST="dpkg -i $DEBFILE"; fi
  [ -n "$INST" ] || fail "no installable package downloaded; manual: pacman -U <pkg.tar.xz> OR dpkg -i <deb>"
  # shellcheck disable=SC2086
  $INST > "$SCRATCH/promote-${TS}.txt" 2>&1; RC=$?; redact < "$SCRATCH/promote-${TS}.txt" >> "$LOGFILE" 2>&1; tail -n 20 "$SCRATCH/promote-${TS}.txt" | redact || true
  [ "$RC" -eq 0 ] || fail "promote install failed (rc=$RC)"
  opencode --version > "$SCRATCH/prodver-${TS}.txt" 2>&1 || true; redact < "$SCRATCH/prodver-${TS}.txt" >> "$LOGFILE" 2>&1; tail -n 3 "$SCRATCH/prodver-${TS}.txt" | redact || true
  result "promote done"
else
  echo "Test-slot verify passed. Production untouched. To promote manually:"
  [ -n "${PKGFILE:-}" ] && echo "  pacman -U $PKGFILE"
  [ -n "${DEBFILE:-}" ] && echo "  dpkg -i $DEBFILE"
  echo "  opencode --version   # expect 2.x"
  echo "Or re-run with --promote --yes [--ref REV]."
fi
if [ "$KEEP_BACKUP" -eq 0 ] && [ "$DO_YES" -eq 1 ]; then log "RESULT" "pruning backups older than 14d (current $BACKUP_DIR kept; --keep-backup disables)"; find "$HOME_DIR" -maxdepth 1 -name 'opencode-backup-v1-*' -mtime +14 ! -path "$BACKUP_DIR" -exec rm -rf {} + 2>/dev/null || true; fi
result "done. backup=$BACKUP_DIR log=$LOGFILE v1=$V1_PIN tag=$TAG"
