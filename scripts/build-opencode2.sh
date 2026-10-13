#!/usr/bin/env bash
# Build the opencode2 standalone binary for Android aarch64 (v2 line).
#
# Usage: ./scripts/build-opencode2.sh
#
# This script:
# 1. Clones anomalyco/opencode at $OPENCODE_V2_REF (or reuses
#    $OPENCODE_V2_WORKTREE when set to an existing checkout)
# 2. Validates source/package/renderer versions, then applies patches/opencode2/
#    (Android build target/optional native guards and Termux update channel).
#    android-target.patch adds opencode-linux-arm64-android to build.ts
#    (no public opencode source ships an Android target; upstream's own
#    v1.0.x build could only have worked with the same local addition)
# 3. Ensures the HOST Bun is exactly $BUN_VERSION (1.4.2) — host AND target
#    are the same official Bun release on the v2 line
# 4. Runs `bun install --ignore-scripts`, then the upstream build entrypoint:
#      cd packages/cli && bun run script/build.ts \
#        --target=opencode-linux-arm64-android --skip-web-ui
# 5. Copies cli-linux-arm64-android/bin/opencode to $DIST_DIR/opencode2.bin
#    (internal filename; the package installs it as libexec/opencode/opencode.bin)
#
# Deliberately ABSENT (vs the v1 scripts/build-opencode.sh):
#   - NO custom Bun/WebKit rebuild — the official `bun build` cross-compiles
#     straight to opencode2-linux-arm64-android.
#   - NO module-graph surgery (no AWS/undici stubbing; Bun 1.4.2 host and
#     target share the same module graph format).
#   - Two source patches: Android target/optional native guards and the
#     repo-backed Termux update check. Everything else uses the upstream build.
#
# Requires: scripts/build-opentui-v2.sh should run first so $OPENTUI_LIB
# exists for the final assertion (the .bin dlopens it at runtime via
# OPENTUI_LIB_PATH, set by bin/opencode2).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env-v2.sh"

echo "=== Building opencode2 (${OPENCODE_V2_REF}) for Android aarch64 ==="

# Resolve the opencode v2 source tree: reuse an existing checkout when asked,
# otherwise clone the pinned tag under build-v2/.
if [ -n "${OPENCODE_V2_WORKTREE:-}" ]; then
    OPENCODE_SRC="$OPENCODE_V2_WORKTREE"
    if [ ! -d "$OPENCODE_SRC/.git" ]; then
        echo "ERROR: OPENCODE_V2_WORKTREE=$OPENCODE_SRC is not a git checkout"
        exit 1
    fi
    echo ">>> Reusing opencode v2 worktree at $OPENCODE_SRC"
else
    OPENCODE_SRC="$OPENCODE_V2_SRC"
    mkdir -p "$WORK_DIR"
    if [ ! -d "$OPENCODE_SRC/.git" ]; then
        echo ">>> Cloning opencode (${OPENCODE_V2_REF})..."
        git clone --depth 1 --branch "$OPENCODE_V2_REF" https://github.com/anomalyco/opencode.git "$OPENCODE_SRC"
    else
        echo ">>> opencode v2 source exists at $OPENCODE_SRC"
        cd "$OPENCODE_SRC"
        CURRENT="$(git describe --tags --exact-match 2>/dev/null || git rev-parse --short HEAD 2>/dev/null || echo unknown)"
        if [ "$CURRENT" != "$OPENCODE_V2_REF" ]; then
            echo "    Checking out $OPENCODE_V2_REF (was $CURRENT)..."
            git fetch --tags origin "$OPENCODE_V2_REF" 2>/dev/null || true
            git checkout --force "$OPENCODE_V2_REF"
        fi
    fi
fi

# Ref-only overrides or stale reused checkouts must not stamp the wrong package
# version or link a mismatched renderer. Check before patching, host Bun install
# or dependency install; this reads metadata only and changes no source files.
echo ">>> Validating OpenCode source/package/OpenTUI versions..."
python3 - "$OPENCODE_SRC" "$OPENCODE_V2_PKGVER" "$OPENTUI_VERSION" <<'V2_SOURCE_CHECK'
import json
import sys
from pathlib import Path

root, version, renderer = sys.argv[1:]
pkg = json.loads((Path(root) / "package.json").read_text())
if pkg.get("version") != version:
    sys.exit("ERROR: source version and OPENCODE_V2_PKGVER disagree")
catalog = pkg["workspaces"]["catalog"]
if any(catalog.get(name) != renderer for name in
       ("@opentui/core", "@opentui/solid", "@opentui/keymap")):
    sys.exit("ERROR: source OpenTUI catalog and OPENTUI_VERSION disagree")
V2_SOURCE_CHECK

# Add the Android target to the upstream build matrix (loud gate).
# Add our opencode2 patch set (loud gate per file).
echo ">>> Applying opencode2 patch set (patches/opencode2/)..."
cd "$OPENCODE_SRC"
for OPENCODE2_PATCH in "$REPO_ROOT"/patches/opencode2/*.patch; do
    [ -f "$OPENCODE2_PATCH" ] || { echo "ERROR: no patches in patches/opencode2/"; exit 1; }
    if git apply --check "$OPENCODE2_PATCH" 2>/dev/null; then
        git apply "$OPENCODE2_PATCH"
        echo "    Applied $(basename "$OPENCODE2_PATCH")"
    elif git apply --check --reverse "$OPENCODE2_PATCH" 2>/dev/null; then
        echo "    $(basename "$OPENCODE2_PATCH") already applied, skipping"
    else
        echo "ERROR: $(basename "$OPENCODE2_PATCH") does not apply to ${OPENCODE_V2_REF}"
        echo "       Regenerate it against this ref."
        exit 1
    fi
done

# Host Bun must be EXACTLY $BUN_VERSION (host and target share one Bun on v2).
# Same install pattern as .github/workflows/build.yml (pinned host Bun step):
# install via the official script only when the current bun differs.
echo ">>> Checking host Bun (want v${BUN_VERSION})..."
GOT="$("$HOST_BUN" --version 2>/dev/null || true)"
if [ "$GOT" != "$BUN_VERSION" ]; then
    echo "    Installing Bun v${BUN_VERSION} (current: ${GOT:-none})..."
    curl -fsSL https://bun.sh/install | bash -s "bun-v${BUN_VERSION}"
    HOST_BUN="$HOME/.bun/bin/bun"
    export PATH="$HOME/.bun/bin:$PATH"
    GOT="$("$HOST_BUN" --version 2>/dev/null || true)"
    if [ "$GOT" != "$BUN_VERSION" ]; then
        echo "ERROR: host Bun is v${GOT:-missing}, want exactly v${BUN_VERSION}"
        exit 1
    fi
fi
echo "    Host Bun: v$GOT"

# Install opencode v2 dependencies (scripts are skipped; nothing native runs
# on the host during install).
echo ">>> Installing opencode v2 dependencies..."
cd "$OPENCODE_SRC"
export PATH="$(dirname "$HOST_BUN"):$PATH"
export BUN_COMPILE_RELEASE="bun-v${BUN_VERSION}"
export OPENCODE_VERSION="$OPENCODE_V2_PKGVER"
export OPENCODE_CHANNEL
"$HOST_BUN" install --ignore-scripts

# Patch the installed @opentui/core JS for the Android runtime (same layer
# v1 used: the bundled JS comes from npm, not from our opentui source
# checkout, so patches/opencode2/*.patch cannot reach it).
#  1. getCurrentNodeAssetTarget(): Bun's Android runtime reports
#     process.platform === "android", which is not in NATIVE_FILE_NAMES, so
#     the TUI dies with "Unsupported OpenTUI Node asset target:
#     android-arm64" before any path override is consulted. Android/Bionic
#     is Linux for asset purposes (identical libopentui.so filename).
#  2. resolveNativeLibraryPath(): honor OPENTUI_LIB_PATH first, restoring
#     the wrapper contract our bin/opencode2 relies on (v2 upstream only
#     knows OTUI_ASSET_ROOT).
# NOTE: build.ts below runs with --skip-install so this step's edits are not
# wiped by build.ts's own `bun install --os=* --cpu=*` pass.
echo ">>> Patching @opentui/core runtime for Android (node_modules)..."
python3 - "$OPENCODE_SRC" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1])
files = sorted(root.rglob("node_modules/@opentui/core/chunk-bun-*.js")) + \
        sorted(root.rglob("node_modules/@opentui/core/chunk-node-*.js"))
if not files:
    print("ERROR: no @opentui/core chunk files found under", root)
    sys.exit(1)
changed = 0
already = 0
verified = {"bun": 0, "node": 0}
for path in files:
    text = path.read_text()
    orig = text
    # Other distributed chunks contain neither runtime function. A chunk that
    # contains either must satisfy BOTH exact anchors, even on an idempotent run.
    if "function getCurrentNodeAssetTarget()" not in text and "async function resolveNativeLibraryPath()" not in text:
        continue
    old_ret = "  return {\n    platform: process.platform,"
    new_ret = ("  return {\n"
               "    // Android/Bionic is Linux for asset purposes.\n"
               "    platform: process.platform === \"android\" ? \"linux\" : process.platform,")
    old_res = ("async function resolveNativeLibraryPath() {\n"
               "  const asset = getNativeAssetDescriptor(getCurrentNodeAssetTarget());")
    new_res = ("async function resolveNativeLibraryPath() {\n"
               "  if (process.env.OPENTUI_LIB_PATH) return process.env.OPENTUI_LIB_PATH;\n"
               "  const asset = getNativeAssetDescriptor(getCurrentNodeAssetTarget());")
    for old, new, label in ((old_ret, new_ret, "Android platform"),
                            (old_res, new_res, "OPENTUI_LIB_PATH-first")):
        if text.count(new) == 1 and text.count(old) == 0:
            continue
        if text.count(old) != 1 or text.count(new) != 0:
            sys.exit(f"ERROR: {label} runtime anchor missing or ambiguous in {path.relative_to(root)}")
        text = text.replace(old, new, 1)
    if text.count(new_ret) != 1 or text.count(new_res) != 1:
        sys.exit(f"ERROR: incomplete Android runtime patch in {path.relative_to(root)}")
    runtime = "bun" if path.name.startswith("chunk-bun-") else "node"
    verified[runtime] += 1
    if text != orig:
        path.write_text(text)
        changed += 1
        print(f"    patched {path.relative_to(root)}")
    else:
        already += 1
print(f"    {changed} newly patched, {already} already patched, {len(files)} total")
if not all(verified.values()):
    sys.exit("ERROR: both Bun and Node runtime chunks must have both Android safeguards")
PY

# Upstream v2 build entrypoint: official bun build for the Android target
# (added by our android-target patch; binary name stays `opencode`).
echo ">>> Building opencode binary (target opencode-linux-arm64-android)..."
mkdir -p "$DIST_DIR"
cd "$OPENCODE_SRC/packages/cli"
"$HOST_BUN" run script/build.ts \
    --target=opencode-linux-arm64-android \
    --skip-web-ui \
    --skip-install \
    --outdir="$DIST_DIR/cli"
cp "$DIST_DIR/cli/cli-linux-arm64-android/bin/opencode" "$DIST_DIR/opencode2.bin"
chmod 755 "$DIST_DIR/opencode2.bin"

# Final assertions: the binary must be non-empty and the v2 renderer library
# (scripts/build-opentui-v2.sh) must exist alongside it.
if [ ! -s "$DIST_DIR/opencode2.bin" ]; then
    echo "ERROR: $DIST_DIR/opencode2.bin is missing or empty"
    exit 1
fi
if [ ! -s "$OPENTUI_LIB" ]; then
    echo "ERROR: $OPENTUI_LIB is missing or empty (run scripts/build-opentui-v2.sh first)"
    exit 1
fi

echo ""
echo "=== opencode2 build complete ==="
echo "Binary: $DIST_DIR/opencode2.bin ($(du -h "$DIST_DIR/opencode2.bin" | cut -f1))"
echo "Renderer lib: $OPENTUI_LIB"
file "$DIST_DIR/opencode2.bin"
