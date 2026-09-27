#!/usr/bin/env bash
# Build the opencode2 standalone binary for Android aarch64 (v2 line).
#
# Usage: ./scripts/build-opencode2.sh
#
# This script:
# 1. Clones anomalyco/opencode at $OPENCODE_V2_REF (or reuses
#    $OPENCODE_V2_WORKTREE when set to an existing checkout)
# 2. Ensures the HOST Bun is exactly $BUN_VERSION (1.4.2) — host AND target
#    are the same official Bun release on the v2 line
# 3. Runs `bun install --ignore-scripts`, then the upstream build entrypoint:
#      cd packages/cli && bun run script/build.ts \
#        --target=opencode2-linux-arm64-android --skip-web-ui
# 4. Copies cli-linux-arm64-android/bin/opencode2 to $DIST_DIR/opencode2.bin
#
# Deliberately ABSENT (vs the v1 scripts/build-opencode.sh):
#   - NO custom Bun/WebKit rebuild — the official `bun build` cross-compiles
#     straight to opencode2-linux-arm64-android.
#   - NO module-graph surgery (no AWS/undici stubbing; Bun 1.4.2 host and
#     target share the same module graph format).
#   - NO opencode source patch — upstream proves none is needed on v2.
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

# Upstream v2 build entrypoint: official bun build for the Android target.
echo ">>> Building opencode2 binary (target opencode2-linux-arm64-android)..."
mkdir -p "$DIST_DIR"
cd "$OPENCODE_SRC/packages/cli"
"$HOST_BUN" run script/build.ts \
    --target=opencode2-linux-arm64-android \
    --skip-web-ui \
    --outdir="$DIST_DIR/cli"
cp "$DIST_DIR/cli/cli-linux-arm64-android/bin/opencode2" "$DIST_DIR/opencode2.bin"
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
