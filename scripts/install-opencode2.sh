#!/usr/bin/env bash
# install-opencode2.sh - On-device installer: V2 takes over the `opencode` command.
# Fork: Konaimav2/opencode-termux. On-device Termux bash (requires bash: pipefail/PIPESTATUS).
# Needs: curl unzip python3, plus dpkg and/or pacman for package install.
#
# TAKEOVER upgrade: installs package `opencode` 2.x, which REPLACES the v1
# files bin/opencode + libexec/opencode/opencode.bin in place
# (2.0.19 > 1.18.27, so pacman -U / dpkg -i upgrade cleanly). Configs,
# sessions and auth are shared locations — nothing is deleted except a
# stray bin/opencode->opencode2 symlink (backed up first).
#
# Steps: preflight (aarch64, Termux, disk 300MB, curl/unzip) -> backup
# existing configs + current bin/opencode (file or symlink, copy-only incl
# auth.json 0600, filenames-only manifest) -> resolve release (--ref default
# latest, GitHub API + python3, pick opencode-2.x zip+deb+pkg assets,
# SHA256SUMS verify when present, graceful fail otherwise) -> install
# (prefer dpkg -i / pacman -U package when available, else flat-zip into
# $PREFIX) -> verify (opencode --version 2.x + --help, local-only; live
# model smoke ONLY with --test-live-model) -> cli.json auto-migration note
# + V1-plugin warning.
#
# Style: bin/opencode2 wrapper resolution, scripts/upgrade-v1-to-v2.sh
# redaction/log patterns (read-only reference).
set -euo pipefail
REPO="Konaimav2/opencode-termux"
DRY_RUN=0
KEEP_BACKUP=0
TEST_LIVE=0
REF="latest"
TS="$(date +%Y%m%d-%H%M%S)"
HOME_DIR="${HOME:-/data/data/com.termux/files/home}"
SCRATCH="${HOME_DIR}/tmp/opencode2-install-${TS}"
# --help must stay side-effect-free: answer before creating any dirs/logs.
for _a in "$@"; do
  case "$_a" in --help|-h)
    cat <<'HELP'
Usage: install-opencode2.sh [--dry-run] [--test-live-model] [--ref REV] [--keep-backup] [--help]
  --help            Show this help (no side effects).
  --dry-run         Print planned actions only; change nothing.
  --test-live-model Also run a live model smoke (opencode run "say hi", costs tokens).
                    Default OFF: verify is local-only (--version + --help).
  --ref REV         Release tag to use (default: latest = resolve at runtime via GitHub API).
  --keep-backup     Disable pruning of backups older than 14 days (prune never
                    touches the current backup).
Takeover (v2 replaces the v1 `opencode` command in place):
  before: bin/opencode + libexec/opencode/ (v1 1.x)
  after:  bin/opencode + libexec/opencode/ (v2 2.x; renderer private inside)
  A stray bin/opencode->opencode2 symlink is removed first (backed up).
  Configs/sessions/auth (shared locations) are never deleted.
Rollback: backups live in ~/opencode2-backup-<TS>/ (see MANIFEST.txt; filenames
  only, no secrets). Reinstall the prior v1 artifact from the previous GitHub
  release, then copy configs back (chmod 0600 auth.json after restore).
  WARNING: inspecting auth.json on screen may expose secrets; do not paste
  them into chats/logs.
HELP
    exit 0 ;;
  esac
done
umask 077
LOGDIR="${HOME_DIR}/.config/opencode/logs"
mkdir -p "$SCRATCH" 2>/dev/null || true
mkdir -p "$LOGDIR" 2>/dev/null || LOGDIR="$HOME_DIR"
LOGFILE="${LOGDIR}/install-opencode2-${TS}.log"
if [ ! -d "$LOGDIR" ] || [ ! -w "$LOGDIR" ]; then LOGDIR="$HOME_DIR"; LOGFILE="${HOME_DIR}/opencode2-install-${TS}.log"; fi
: > "$LOGFILE" 2>/dev/null || LOGFILE="/dev/stdout"
BACKUP_DIR="${HOME_DIR}/opencode2-backup-${TS}"
log(){ printf '[%s] [%s] %s\n' "$(date +%H:%M:%S)" "$1" "$(printf '%s' "$2" | redact)" | tee -a "$LOGFILE"; }
step(){ log "STEP" "$1"; }
result(){ log "RESULT" "$1"; }
redact(){ sed -E -e 's/eyJ[A-Za-z0-9_.-]{10,}[A-Za-z0-9_.-]*/<redacted-jwt>/g' -e 's/sk-[A-Za-z0-9_-]{10,}/<redacted>/g' -e 's/gh[pousr]_[A-Za-z0-9_]{10,}/<redacted>/g' -e 's/github_pat_[A-Za-z0-9_]{10,}/<redacted>/g' -e 's/(Bearer[ :]*)[A-Za-z0-9_.-]+/\1<redacted>/gi' -e 's/((api[_-]?key|token|secret|password)["'"'"'=: ]+)[^"'"'"' ]+/\1<redacted>/gi'; }
usage(){
cat <<'HELP'
Usage: install-opencode2.sh [--dry-run] [--test-live-model] [--ref REV] [--keep-backup] [--help]
  --help            Show this help.
  --dry-run         Print planned actions only; change nothing.
  --test-live-model Also run a live model smoke (costs tokens). Default OFF.
  --ref REV         Release tag to use (default: latest = resolve at runtime via GitHub API).
  --keep-backup     Disable pruning of backups older than 14 days.
HELP
}
while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --test-live-model) TEST_LIVE=1; shift ;;
    --keep-backup) KEEP_BACKUP=1; shift ;;
    --ref) REF="${2:?--ref needs a value}"; shift 2 ;;
    --ref=*) REF="${1#--ref=}"; shift ;;
    *) echo "unknown flag: $1 (see --help)" >&2; exit 2 ;;
  esac
done
fail(){ echo "ABORT: $1" | redact | tee -a "$LOGFILE" >&2; echo "Log: $LOGFILE" >&2; exit 1; }
# Only ever remove this script's own scratch dir, and only on failure.
SCRATCH_OK=0
cleanup_scratch(){ if [ "$SCRATCH_OK" -eq 0 ]; then rm -rf "$SCRATCH" 2>/dev/null || true; fi; }
trap cleanup_scratch ERR
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
if [ -n "$FREE_KB" ] && [ "$FREE_KB" -lt 307200 ]; then fail "disk <300MB free (${FREE_KB}KB)"; fi
result "disk ok (${FREE_KB:-?}KB free)"
V1_PIN="$(opencode --version 2>/dev/null | head -n1 || echo none)"
V2_PIN="$(opencode2 --version 2>/dev/null | head -n1 || echo none)"
result "existing v1: $V1_PIN / existing v2: $V2_PIN"
printf 'V1_PIN=%s\nV2_PIN=%s\nDATE=%s\nREF=%s\n' "$V1_PIN" "$V2_PIN" "$TS" "$REF" >> "$LOGFILE"
if [ "$DRY_RUN" -eq 1 ]; then
  log "STEP" "[dry-run] would backup to $BACKUP_DIR (configs copy-only: opencode.json/tui.json/cli.json, auth.json 0600, current bin/opencode file-or-symlink + libexec/opencode/ snapshot; 0700 dir; filenames-only MANIFEST.txt)"
  log "STEP" "[dry-run] would resolve ${REF} via api.github.com/repos/${REPO}/releases, pick opencode-2.x zip+deb+pkg assets (+SHA256SUMS best-effort verify)"
  log "STEP" "[dry-run] would download to ~ (keep for rollback), size>10MB, unzip -l lists opencode+opencode.bin+.so"
  log "STEP" "[dry-run] would remove a stray bin/opencode->opencode2 symlink if present (backed up), then upgrade in place: prefer pacman -U <pkg.tar.xz> or dpkg -i <deb>; else flat-zip into \$PREFIX (bin/opencode + libexec/opencode/)"
  log "STEP" "[dry-run] would verify local-only: opencode --version (2.x) + --help, cli.json auto-migration note, rg note (live model smoke only with --test-live-model)"
  log "STEP" "[dry-run] WARN: V1 plugins do NOT run on V2; server API callers must be ported (no auto-port)"
  usage; echo "Log: $LOGFILE"; SCRATCH_OK=1; exit 0
fi
step "backup -> $BACKUP_DIR"
mkdir -p "$BACKUP_DIR"
chmod 0700 "$BACKUP_DIR"
N=0
[ -f "$HOME_DIR/.config/opencode/opencode.json" ] && cp "$HOME_DIR/.config/opencode/opencode.json" "$BACKUP_DIR/" && N=$((N+1))
[ -f "$HOME_DIR/.config/opencode/tui.json" ] && cp "$HOME_DIR/.config/opencode/tui.json" "$BACKUP_DIR/" && N=$((N+1))
[ -f "$HOME_DIR/.config/opencode/cli.json" ] && cp "$HOME_DIR/.config/opencode/cli.json" "$BACKUP_DIR/cli.json.v2existing" && N=$((N+1))
if [ -f "$HOME_DIR/.local/share/opencode/auth.json" ]; then cp "$HOME_DIR/.local/share/opencode/auth.json" "$BACKUP_DIR/" && chmod 0600 "$BACKUP_DIR/auth.json" && N=$((N+1)); fi
printf '%s\n' "v1=$V1_PIN" > "$BACKUP_DIR/versions.txt"
printf '%s\n' "v2=$V2_PIN" >> "$BACKUP_DIR/versions.txt"
if [ -n "${PREFIX:-}" ]; then
  mkdir -p "$BACKUP_DIR/prefix-snapshot" 2>/dev/null || true
  if [ -L "$PREFIX/bin/opencode" ]; then
    readlink "$PREFIX/bin/opencode" > "$BACKUP_DIR/prefix-snapshot/opencode.symlink-target.txt" 2>/dev/null || true
    cp -P "$PREFIX/bin/opencode" "$BACKUP_DIR/prefix-snapshot/" && N=$((N+1))
  elif [ -f "$PREFIX/bin/opencode" ]; then
    cp "$PREFIX/bin/opencode" "$BACKUP_DIR/prefix-snapshot/" && N=$((N+1))
  fi
  for f in opencode.bin libtagfix.so libopentui.so; do
    [ -f "$PREFIX/libexec/opencode/$f" ] && cp "$PREFIX/libexec/opencode/$f" "$BACKUP_DIR/prefix-snapshot/" && N=$((N+1))
  done
fi
ls -la "$BACKUP_DIR" > "$BACKUP_DIR/MANIFEST.txt" 2>&1
result "backup ok ($N items) -> $BACKUP_DIR (see MANIFEST.txt; filenames only, no secrets)"
step "resolve release ref=$REF"
if [ "$REF" = "latest" ]; then API="https://api.github.com/repos/${REPO}/releases/latest";
else API="https://api.github.com/repos/${REPO}/releases/tags/${REF}"; fi
JSON="$SCRATCH/opencode2-rel-${TS}.json"
curl -fsSL "$API" -o "$JSON" || fail "GitHub API failed ($API). If no opencode 2.x Android asset is published yet, CI must publish first."
TAG="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("tag_name",""))' "$JSON")"
[ -n "$TAG" ] || fail "could not parse tag_name from release JSON"
ZIP_URL="$(python3 -c 'import json,sys; a=json.load(open(sys.argv[1])).get("assets",[]); print("\n".join(x.get("browser_download_url","") for x in a))' "$JSON" | grep -E 'opencode-2[0-9.]*-android-aarch64\.zip$' | head -n1 || true)"
DEB_URL="$(python3 -c 'import json,sys; a=json.load(open(sys.argv[1])).get("assets",[]); print("\n".join(x.get("browser_download_url","") for x in a))' "$JSON" | grep -E 'opencode_2[0-9.]*_aarch64\.deb$' | head -n1 || true)"
PKG_URL="$(python3 -c 'import json,sys; a=json.load(open(sys.argv[1])).get("assets",[]); print("\n".join(x.get("browser_download_url","") for x in a))' "$JSON" | grep -E 'opencode-2[0-9.]*-aarch64\.pkg\.tar\.xz$' | head -n1 || true)"
[ -n "$ZIP_URL" ] || fail "no opencode 2.x Android zip asset in $TAG yet (CI must publish first). Assets seen: $(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("assets",[])))' "$JSON")"
result "tag=$TAG zip=$(basename "$ZIP_URL")"
step "download (keep artifacts for rollback)"
ZIPFILE="${HOME_DIR}/$(basename "$ZIP_URL")"
DEBFILE=""; PKGFILE=""
[ -n "$DEB_URL" ] && DEBFILE="${HOME_DIR}/$(basename "$DEB_URL")"
[ -n "$PKG_URL" ] && PKGFILE="${HOME_DIR}/$(basename "$PKG_URL")"
[ -f "$ZIPFILE" ] || curl -fSL "$ZIP_URL" -o "$ZIPFILE" || fail "zip download failed"
SZ="$(wc -c < "$ZIPFILE" | tr -d ' ')"
[ "$SZ" -gt 10485760 ] || { rm -f "$ZIPFILE"; fail "zip too small (${SZ}B); expected >10MB (removed, re-run to re-download)"; }
unzip -l "$ZIPFILE" 2>/dev/null | redact > "$SCRATCH/ziplist-${TS}.txt"
grep -qE '(^|/)opencode$' "$SCRATCH/ziplist-${TS}.txt" || fail "zip missing wrapper 'opencode'"
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
[ -z "$DEB_URL" ] || { [ -f "$DEBFILE" ] || curl -fSL "$DEB_URL" -o "$DEBFILE" || log "RESULT" "WARN: deb download failed, package-via-deb unavailable"; }
[ -z "$PKG_URL" ] || { [ -f "$PKGFILE" ] || curl -fSL "$PKG_URL" -o "$PKGFILE" || log "RESULT" "WARN: pkg download failed, package-via-pacman unavailable"; }
step "upgrade in place (configs/sessions/auth are shared locations; only a stray symlink is removed)"
if [ -L "${PREFIX:-/nonexistent}/bin/opencode" ]; then
  log "RESULT" "removing stray symlink $PREFIX/bin/opencode -> $(readlink "$PREFIX/bin/opencode") (backed up in $BACKUP_DIR/prefix-snapshot/)"
  rm -f "$PREFIX/bin/opencode"
fi
INST=""
if command -v pacman >/dev/null 2>&1 && [ -n "$PKGFILE" ] && [ -f "$PKGFILE" ]; then INST="pacman -U $PKGFILE";
elif command -v dpkg >/dev/null 2>&1 && [ -n "$DEBFILE" ] && [ -f "$DEBFILE" ]; then INST="dpkg -i $DEBFILE";
elif [ -n "$PKGFILE" ] && [ -f "$PKGFILE" ]; then INST="pacman -U $PKGFILE";
elif [ -n "$DEBFILE" ] && [ -f "$DEBFILE" ]; then INST="dpkg -i $DEBFILE"; fi
if [ -n "$INST" ]; then
  # shellcheck disable=SC2086
  $INST > "$SCRATCH/install-${TS}.txt" 2>&1; RC=$?; redact < "$SCRATCH/install-${TS}.txt" >> "$LOGFILE" 2>&1; tail -n 20 "$SCRATCH/install-${TS}.txt" | redact || true
  [ "$RC" -eq 0 ] || fail "package install failed (rc=$RC)"
  result "package install done ($INST)"
else
  [ -n "${PREFIX:-}" ] || fail "no installable package downloaded and \$PREFIX unset; manual: pacman -U <pkg.tar.xz> OR dpkg -i <deb>"
  log "RESULT" "NOTE: no package manager path; flat-zip install into \$PREFIX"
  mkdir -p "$PREFIX/bin" "$PREFIX/libexec/opencode"
  unzip -o "$ZIPFILE" -d "$SCRATCH/flat" > "$SCRATCH/unzip-${TS}.txt" 2>&1; tail -n 5 "$SCRATCH/unzip-${TS}.txt" | redact >> "$LOGFILE" 2>&1
  [ -f "$SCRATCH/flat/opencode" ] || fail "extract missing wrapper 'opencode'"
  [ -f "$SCRATCH/flat/opencode.bin" ] || fail "extract missing opencode.bin"
  cp "$SCRATCH/flat/opencode" "$PREFIX/bin/opencode"
  cp "$SCRATCH/flat/opencode.bin" "$PREFIX/libexec/opencode/opencode.bin"
  for f in "$SCRATCH"/flat/*.so; do [ -f "$f" ] && cp "$f" "$PREFIX/libexec/opencode/"; done
  chmod +x "$PREFIX/bin/opencode" "$PREFIX/libexec/opencode/opencode.bin"
  result "flat-zip install done (bin/opencode + libexec/opencode/)"
fi
O2="opencode"
command -v opencode >/dev/null 2>&1 || O2="${PREFIX:-}/bin/opencode"
step "verify (local-only; no network/billing)"
"$O2" --version > "$SCRATCH/ver-${TS}.txt" 2>&1; RC=$?; redact < "$SCRATCH/ver-${TS}.txt" >> "$LOGFILE" 2>&1; tail -n 5 "$SCRATCH/ver-${TS}.txt" | redact || true
[ "$RC" -eq 0 ] || fail "opencode --version failed (rc=$RC)"
VER="$(head -n1 "$SCRATCH/ver-${TS}.txt" || echo unknown)"
case "$VER" in 2.*) result "version ok: $VER";; *) fail "expected 2.x, got: $VER";; esac
"$O2" --help > "$SCRATCH/help-${TS}.txt" 2>&1 || fail "opencode --help failed"; redact < "$SCRATCH/help-${TS}.txt" >> "$LOGFILE" 2>&1; tail -n 10 "$SCRATCH/help-${TS}.txt" | redact || true
if [ "$TEST_LIVE" -eq 1 ]; then
  step "live model smoke (opt-in, costs tokens)"
  if command -v timeout >/dev/null 2>&1; then timeout 120 "$O2" run "say hi" > "$SCRATCH/live-${TS}.txt" 2>&1; RC=$?;
  else "$O2" run "say hi" > "$SCRATCH/live-${TS}.txt" 2>&1; RC=$?; fi
  redact < "$SCRATCH/live-${TS}.txt" >> "$LOGFILE" 2>&1; tail -n 20 "$SCRATCH/live-${TS}.txt" | redact || true
  [ "$RC" -eq 0 ] || fail "headless run failed (rc=$RC). Log: $LOGFILE"
else
  result "live model smoke skipped (re-run with --test-live-model to spend tokens)"
fi
if [ -f "$HOME_DIR/.config/opencode/cli.json" ]; then result "auto-migration: cli.json present (first V2 start creates it from tui.json when missing)";
else log "RESULT" "NOTE: no cli.json yet; first V2 start auto-creates ~/.config/opencode/cli.json from tui.json"; fi
result "v1 files replaced by this upgrade (rollback: reinstall the v1 1.x artifact, then copy configs back from $BACKUP_DIR)"
echo "WARN: V1 plugins do NOT run on V2; server API callers must be ported. Checklist (no auto-port):"
echo "  1) list plugins: ls ~/.config/opencode/plugin 2>/dev/null (do NOT cat auth.json/opencode.json to chat)"
echo "  2) check each plugin README for a V2-compatible release; reinstall per-V2 docs"
echo "  3) port scripts calling the opencode server API to the V2 CLI/API surface; re-run headless 'run' smoke per caller"
if [ "$KEEP_BACKUP" -eq 0 ]; then log "RESULT" "pruning install-script backups older than 14d (current $BACKUP_DIR kept; --keep-backup disables)"; find "$HOME_DIR" -maxdepth 1 -name 'opencode2-backup-*' -mtime +14 ! -path "$BACKUP_DIR" -exec rm -rf {} + 2>/dev/null || true; fi
SCRATCH_OK=1
result "done. backup=$BACKUP_DIR log=$LOGFILE v1=$V1_PIN v2=$VER tag=$TAG"
