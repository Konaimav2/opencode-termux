#!/usr/bin/env bash
# Build OpenCode standalone binary for Android aarch64
#
# Usage: ./scripts/build-opencode.sh
#
# This script:
# 1. Clones OpenCode if needed
# 2. Uses the ARM64 libopentui.so built by scripts/build-opentui.sh
# 3. Synthesizes @opentui/core-linux-arm64 in node_modules for ARM64 Android
# 4. Runs the TypeScript build script to create the standalone binary
# 5. Restores original @opentui/core-linux-x64 files
#
# Requires:
# - Android Bun binary built (scripts/build-bun.sh)
# - opentui ARM64 .so built (scripts/build-opentui.sh)
# - Host Bun installed (for bundling)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

HOST_BUN="${HOST_BUN:-bun}"

echo "=== Building OpenCode v${OPENCODE_VERSION} for Android aarch64 ==="

# Clone OpenCode if needed
if [ ! -d "$OPENCODE_SRC/.git" ]; then
    echo ">>> Cloning OpenCode..."
    git clone --depth 1 --branch "v${OPENCODE_VERSION}" https://github.com/anomalyco/opencode.git "$OPENCODE_SRC"
else
    echo ">>> OpenCode source exists at $OPENCODE_SRC"
    cd "$OPENCODE_SRC"
    CURRENT=$(git describe --tags --exact-match 2>/dev/null || git rev-parse --short HEAD 2>/dev/null || echo "unknown")
    if [ "$CURRENT" != "v${OPENCODE_VERSION}" ]; then
        echo "    Checking out v${OPENCODE_VERSION} (was $CURRENT)..."
        git fetch --tags origin "v${OPENCODE_VERSION}" 2>/dev/null || true
        git checkout --force "v${OPENCODE_VERSION}"
    fi
fi

OPENCODE_PKG="$OPENCODE_SRC/packages/opencode"

# Install OpenCode dependencies
echo ">>> Installing OpenCode dependencies..."
cd "$OPENCODE_SRC"
"$HOST_BUN" install --ignore-scripts

# Find the Android bun binary
ANDROID_BUN="$BUN_BUILD/bun"
if [ ! -f "$ANDROID_BUN" ]; then
    echo "ERROR: Android bun binary not found at $ANDROID_BUN"
    echo "       Run scripts/build-bun.sh first."
    exit 1
fi

# Use the ARM64 libopentui.so built by scripts/build-opentui.sh.
# build-opentui.sh checks out opentui v0.4.2 (the version OpenCode depends on)
# and cross-compiles it for aarch64-linux-android, producing:
#   $OPENTUI_SRC/packages/core/src/lib/aarch64-linux-android/libopentui.so
echo ">>> Locating ARM64 libopentui.so from opentui build..."

# Determine the @opentui/core version OpenCode depends on for the synthesized
# core-linux-arm64 package metadata. The package may be hoisted to the workspace
# root or kept inside packages/opencode/node_modules.
OPENTUI_CORE_PKG_JSON=""
for candidate in \
    "$OPENCODE_PKG/node_modules/@opentui/core/package.json" \
    "$OPENCODE_SRC/node_modules/@opentui/core/package.json"
do
    if [ -f "$candidate" ]; then
        OPENTUI_CORE_PKG_JSON="$candidate"
        break
    fi
done
if [ -z "$OPENTUI_CORE_PKG_JSON" ]; then
    echo "ERROR: @opentui/core not installed. Run bun install first."
    echo "       Searched:"
    echo "         $OPENCODE_PKG/node_modules/@opentui/core/package.json"
    echo "         $OPENCODE_SRC/node_modules/@opentui/core/package.json"
    exit 1
fi
OPENTUI_CORE_VERSION=$(jq -r '.version' "$OPENTUI_CORE_PKG_JSON")
echo "    @opentui/core version: $OPENTUI_CORE_VERSION"

ARM64_LIBOPENTUI="$OPENTUI_SRC/packages/core/src/lib/aarch64-linux-android/libopentui.so"
if [ ! -f "$ARM64_LIBOPENTUI" ]; then
    echo "ERROR: ARM64 libopentui.so not found at $ARM64_LIBOPENTUI"
    echo "       Run scripts/build-opentui.sh first."
    exit 1
fi
echo "    Using ARM64 libopentui.so ($(du -h "$ARM64_LIBOPENTUI" | cut -f1))"

is_android_shared_object() {
    local file="$1"
    local needed
    needed=$(readelf -d "$file" 2>/dev/null | grep 'Shared library:' || true)
    ! echo "$needed" | grep -Eq 'libc\.so\.6|libpthread\.so\.0|libdl\.so\.2|libutil\.so\.1'
}

# Find all @opentui/core-linux-x64 package directories under node_modules.
# We must patch every occurrence because Bun's module resolver can pick up
# the package from multiple hoisted locations, and the .so inside each one
# must be ARM64 and must load from a real filesystem path on Android
# (Bun's /$bunfs/root/ virtual paths are not reliably intercepted on Android).
OPENTUI_PACKAGES=()
while IFS= read -r -d '' pkg_dir; do
    OPENTUI_PACKAGES+=("$pkg_dir")
done < <(find "$OPENCODE_SRC" -path '*/node_modules/@opentui/core-linux-x64' -type d -print0 2>/dev/null || true)

if [ ${#OPENTUI_PACKAGES[@]} -eq 0 ]; then
    echo "ERROR: Could not find @opentui/core-linux-x64 in node_modules"
    echo "       The build will embed the wrong architecture"
    exit 1
fi

# Backup list: "so_path:backup_path index_path:backup_path ..."
OPENTUI_BACKUPS=()

echo ">>> Patching @opentui/core-linux-x64 packages for Android aarch64..."
for pkg_dir in "${OPENTUI_PACKAGES[@]}"; do
    so_file="$pkg_dir/libopentui.so"

    if [ ! -f "$so_file" ]; then
        echo "WARNING: $so_file not found, skipping $pkg_dir"
        continue
    fi

    # Backup and swap the .so
    so_backup="${so_file}.x64.bak"
    cp "$so_file" "$so_backup"
    cp "$ARM64_LIBOPENTUI" "$so_file"
    OPENTUI_BACKUPS+=("$so_file:$so_backup")
    echo "    Swapped $so_file"

    # Patch the index files to load from the filesystem on Android.
    # Since 0.4.5 the package ships index.js (ESM) and index.bun.js (bun
    # condition, which does `await import("./libopentui.so", { with: { type:
    # "file" } })`). Bun's /$bunfs/root/ virtual path works on desktop Linux
    # but is not intercepted by the Android runtime, so the dlopen/openat
    # fails with ENOENT. Bun standalone on Android starts with an EMPTY
    # process.env, so the path is hard-coded to the Termux lib dir (the
    # packaging step installs libopentui.so there). Both entries are
    # replaced with a CommonJS-compatible loader that resolves the real
    # filesystem path without touching the environment.
    for idx_name in index.js index.bun.js; do
        idx_file="$pkg_dir/$idx_name"
        if [ -f "$idx_file" ]; then
            idx_backup="${idx_file}.bak"
            cp "$idx_file" "$idx_backup"
            cat > "$idx_file" <<'IDXEOF'
// OPENCODE_BUNDLER_SHIM: resolve libopentui.so from the real filesystem.
// Bun's /$bunfs/root/ virtual paths are not intercepted on Android, and
// Bun standalone on Android starts with an EMPTY process.env, so we cannot
// use OPENTUI_LIB_PATH. Resolution order: libopentui.so next to the
// running executable (side-by-side/flat layout), then the Termux lib dir
// (packaged layout).
const fs = require("fs");
const path = require("path");
function androidLibPath() {
  try {
    const next = path.join(path.dirname(process.execPath), "libopentui.so");
    if (fs.existsSync(next)) return next;
  } catch (e) {}
  return "/data/data/com.termux/files/usr/lib/libopentui.so";
}
module.exports = androidLibPath();
IDXEOF
            OPENTUI_BACKUPS+=("$idx_file:$idx_backup")
            echo "    Patched $idx_file"
        fi
    done
done

# Synthesize @opentui/core-linux-arm64 so opentui's platform detection resolves
# the correct package on Android/Termux arm64. The host build only installs
# core-linux-x64, so the arm64 optional dependency is missing. Without this,
# zig.ts throws "opentui is not supported on the current platform: linux-arm64".
CORE_LINUX_ARM64_DIR="$OPENCODE_SRC/node_modules/@opentui/core-linux-arm64"
if [ ! -d "$CORE_LINUX_ARM64_DIR" ]; then
    echo ">>> Creating @opentui/core-linux-arm64 package..."
    mkdir -p "$CORE_LINUX_ARM64_DIR"
    cat > "$CORE_LINUX_ARM64_DIR/package.json" <<EOF
{
  "name": "@opentui/core-linux-arm64",
  "version": "$OPENTUI_CORE_VERSION",
  "main": "index.js",
  "license": "MIT"
}
EOF
    cp "$ARM64_LIBOPENTUI" "$CORE_LINUX_ARM64_DIR/libopentui.so"
    cat > "$CORE_LINUX_ARM64_DIR/index.js" <<'EOF'
const fs = require("fs");
const path = require("path");
function androidLibPath() {
  try {
    const next = path.join(path.dirname(process.execPath), "libopentui.so");
    if (fs.existsSync(next)) return next;
  } catch (e) {}
  return "/data/data/com.termux/files/usr/lib/libopentui.so";
}
module.exports = androidLibPath();
EOF
    echo "    Created $CORE_LINUX_ARM64_DIR"
else
    echo ">>> @opentui/core-linux-arm64 already exists, updating .so and version..."
    cat > "$CORE_LINUX_ARM64_DIR/package.json" <<EOF
{
  "name": "@opentui/core-linux-arm64",
  "version": "$OPENTUI_CORE_VERSION",
  "main": "index.js",
  "license": "MIT"
}
EOF
    cp "$ARM64_LIBOPENTUI" "$CORE_LINUX_ARM64_DIR/libopentui.so"
    cat > "$CORE_LINUX_ARM64_DIR/index.js" <<'EOF'
module.exports = process.env["OPENTUI_LIB_PATH"] || "/data/data/com.termux/files/usr/lib/libopentui.so";
EOF
fi

# Patch @opentui/core's generated FFI wrapper. Bun validates numeric arguments
# against the declared FFI type before Zig sees them; Android terminal/layout
# churn can briefly produce negative viewport sizes, which otherwise throws
# "integer does not fit in destination type" for u32 arguments.
# Since @opentui/core 0.4.5 the generated JS lives in chunk-bun-*.js /
# chunk-node-*.js files (no more index-*.js), and existsSync became
# existsSync3 after bundling. Bun standalone on Android has an EMPTY
# process.env, so instead of an OPENTUI_LIB_PATH override we prepend an
# execPath-relative resolution to the targetLibPath computation.
echo ">>> Patching @opentui/core FFI u32 boundary..."
while IFS= read -r -d '' opentui_js; do
    if grep -q "function toU32(value)" "$opentui_js" && grep -q "opencodeExecDir" "$opentui_js"; then
        echo "    $opentui_js already patched"
        continue
    fi
    python3 - "$opentui_js" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
changes = []

# 1. Native library location: Bun standalone on Android has an EMPTY
#    process.env, so resolve libopentui.so next to the running executable
#    before the default resolution (which imports the synthesized
#    @opentui/core-linux-arm64 package — itself shimmed the same way).
if "opencodeExecDir" not in text and "targetLibPath" in text:
    done = False
    for exists_fn in ("existsSync3", "existsSync2", "existsSync"):
        old = (
            'if (isBunfsPath(targetLibPath)) {\n'
            '    targetLibPath = targetLibPath.replace("../", "");\n'
            '  }\n'
            f'  if (!{exists_fn}(targetLibPath)) {{'
        )
        new = (
            'if (isBunfsPath(targetLibPath)) {\n'
            '    targetLibPath = targetLibPath.replace("../", "");\n'
            '  }\n'
            '  {\n'
            '    const execp = process.execPath || "";\n'
            '    const slash = execp.lastIndexOf("/");\n'
            '    const execDirLib = (slash > 0 ? execp.slice(0, slash) : ".") + "/libopentui.so";\n'
            f'    if ({exists_fn}(execDirLib)) {{\n'
            '      targetLibPath = execDirLib;\n'
            '    }\n'
            '  }\n'
            f'  if (!{exists_fn}(targetLibPath)) {{'
        )
        if old in text:
            text = text.replace(old, new, 1)
            changes.append(f"execdir-libpath@{exists_fn}")
            done = True
            break
    if not done:
        # Indentation-agnostic fallback: insert after the isBunfsPath block.
        import re
        m = re.search(
            r'(if \(isBunfsPath\(targetLibPath\)\) \{[^}]*\}\n)(\s*if\s*\(!\w+\(targetLibPath\)\))',
            text,
        )
        if m:
            text = text.replace(
                m.group(2),
                '  {\n    const execp = process.execPath || "";\n    const slash = execp.lastIndexOf("/");\n    const execDirLib = (slash > 0 ? execp.slice(0, slash) : ".") + "/libopentui.so";\n    if (existsSync(execDirLib)) {\n      targetLibPath = execDirLib;\n    }\n  }\n' + m.group(2),
                1,
            )
            changes.append("execdir-libpath@fallback")
        else:
            print(f"    WARNING: {path.name}: targetLibPath block found but no insertion point")

# 2. toU32 sanitization for FFI u32 arguments.
if "function toU32(value)" not in text:
    anchor = 'function toNumber(value) {\n  return typeof value === "bigint" ? Number(value) : value;\n}\n'
    helper = 'function toU32(value) {\n  if (!Number.isFinite(value) || value <= 0) return 0;\n  return Math.min(Math.trunc(value), 4294967295);\n}\n'
    if anchor in text:
        text = text.replace(anchor, anchor + helper, 1)
        changes.append("toU32")
    else:
        anchor2 = "  textBufferViewSetWrapWidth(view, width) {"
        if anchor2 in text:
            text = text.replace(anchor2, helper + anchor2, 1)
            changes.append("toU32@alt")

for old, new, tag in [
    ('this.opentui.symbols.textBufferViewSetWrapWidth(view, width);',
     'this.opentui.symbols.textBufferViewSetWrapWidth(view, toU32(width));', 'wrapWidth'),
    ('this.opentui.symbols.textBufferViewSetFirstLineOffset(view, offset);',
     'this.opentui.symbols.textBufferViewSetFirstLineOffset(view, toU32(offset));', 'firstLine'),
    ('this.opentui.symbols.textBufferViewSetViewportSize(view, width, height);',
     'this.opentui.symbols.textBufferViewSetViewportSize(view, toU32(width), toU32(height));', 'vpSize'),
    ('this.opentui.symbols.textBufferViewSetViewport(view, x, y, width, height);',
     'this.opentui.symbols.textBufferViewSetViewport(view, toU32(x), toU32(y), toU32(width), toU32(height));', 'viewport'),
    ('this.opentui.symbols.textBufferViewMeasureForDimensions(view, width, height, resultPtr);',
     'this.opentui.symbols.textBufferViewMeasureForDimensions(view, toU32(width), toU32(height), resultPtr);', 'measure'),
]:
    if old in text:
        text = text.replace(old, new)
        changes.append(tag)

# 3. Renderer span-feed guard carried from v0.2.1/v0.2.2: the memory-buffered
#    feed output path panics on Android after several responses.
ufe_old = '    const useFeedOutput = !this._usesProcessStdout && !useMemoryBufferedOutput;'
if ufe_old in text:
    text = text.replace(ufe_old, '    const useFeedOutput = false;')
    changes.append("useFeedOutput")

# 4. Tree-sitter worker asset init: with splitting disabled the worker asset
#    resolution runs eagerly at module init, and the file-asset loader has
#    no default export under host Bun 1.3.2, crashing the whole graph in
#    normalizeLoadedFilePath before the TUI even starts. The resolved path
#    is unused at runtime (OTUI_TREE_SITTER_WORKER_PATH define takes
#    precedence), so make the init non-fatal.
old_worker = 'var bundledTreeSitterWorkerPath = await resolveBundledFilePath(PARSER_WORKER_ASSET_KEY, () => import("@opentui/core/parser.worker", { with: { type: "file" } }), new URL("../lib/tree-sitter/parser.worker.js", import.meta.url), import.meta.url, { useAssetRoot: false });'
new_worker = 'var bundledTreeSitterWorkerPath = await resolveBundledFilePath(PARSER_WORKER_ASSET_KEY, () => import("@opentui/core/parser.worker", { with: { type: "file" } }), new URL("../lib/tree-sitter/parser.worker.js", import.meta.url), import.meta.url, { useAssetRoot: false }).catch(() => undefined);'
if old_worker in text:
    text = text.replace(old_worker, new_worker, 1)
    changes.append("worker-asset-catch")

path.write_text(text)
print(f"    {path.name}: {'+'.join(changes) if changes else 'nothing to do'}")
PY
done < <(find "$OPENCODE_SRC" \( -path '*/node_modules/@opentui/core/chunk-bun-*.js' -o -path '*/node_modules/@opentui/core/chunk-node-*.js' -o -path '*/node_modules/@opentui/core/index-*.js' \) -type f -print0 2>/dev/null || true)

# Patch OpenCode source for Android/Termux runtime constraints.
# We cannot modify the upstream source directly, so apply local patches here.
echo ">>> Patching OpenCode source for Android/Termux..."

# Patch OpenCode source for Android/Termux runtime constraints via a
# versioned git patch (validated against the pinned OpenCode tag). The
# patch covers:
#   - packages/core/src/global.ts          Termux-safe cache/tmp paths
#   - packages/core/src/filesystem/watcher.ts  disable @parcel/watcher
#   - packages/opencode/src/config/config.ts   skip background npm install
#   - packages/tui/src/audio.ts            disable TUI audio
#   - packages/tui/src/app.tsx             TUI startup diagnostics
#   - packages/core/src/cross-spawn-spawner.ts no negative-pid kill / detached
#   - packages/core/src/shell.ts           killTree without negative-pid kill
OPENCODE_PATCH="$REPO_ROOT/patches/opencode/android-termux-1.18.patch"
if [ -f "$OPENCODE_PATCH" ]; then
    echo ">>> Applying OpenCode Android patch (patches/opencode/android-termux-1.18.patch)..."
    cd "$OPENCODE_SRC"
    if git apply --check "$OPENCODE_PATCH" 2>/dev/null; then
        git apply "$OPENCODE_PATCH"
        echo "    Patch applied successfully"
    elif git apply --check --reverse "$OPENCODE_PATCH" 2>/dev/null; then
        echo "    Patch already applied, skipping"
    else
        echo "ERROR: OpenCode Android patch does not apply to OpenCode ${OPENCODE_VERSION}"
        echo "       Regenerate patches/opencode/android-termux-1.18.patch against this tag."
        exit 1
    fi
    cd "$REPO_ROOT"
else
    echo "ERROR: $OPENCODE_PATCH not found"
    exit 1
fi

# Work around missing type-only AWS ESM exports that Bun 1.3.2 still tries
# to resolve while bundling. Newer Bun versions are better here, but 1.3.2
# remains pinned because its standalone module graph is compatible with the
# Android Bun 1.2.13 runtime. (1.18.x no longer depends on the Cognito
# provider directly; stub it only if present as a transitive dependency.)
AWS_COGNITO_INDEX="$OPENCODE_SRC/node_modules/.bun/@aws-sdk+credential-provider-cognito-identity@"*/node_modules/@aws-sdk/credential-provider-cognito-identity/dist-es/index.js
for aws_index in $AWS_COGNITO_INDEX; do
    if [ -f "$aws_index" ]; then
        cat > "$aws_index" <<'AWSEOF'
const unsupported = () => {
  throw new Error("@aws-sdk/credential-provider-cognito-identity is not bundled in the Android build")
}
export const fromCognitoIdentity = unsupported
export const fromCognitoIdentityPool = unsupported
AWSEOF
        echo "    Patched $aws_index (stub optional Cognito provider)"
    fi
done

# 7. Work around a Bun 1.3.2 bundler bug: `export * from "undici"` (Bun maps
#    "undici" to its built-in module) compiles into a reference to a namespace
#    binding that is never emitted, so the module graph crashes at load with
#    "Xyz is not defined" (hit by @effect/platform-node/dist/Undici.js since
#    OpenCode 1.18.x bundles effect 4.0.0-beta.83). Regenerate the shim with
#    explicit named re-exports enumerated from the host runtime instead.
#    NOTE: write via temp+mv (never truncate in place) — Bun hardlinks
#    identical files within node_modules, and truncating would corrupt the
#    other link(s).
UNDICI_SHIMS="$OPENCODE_SRC/node_modules/.bun"/@effect+platform-node@*/node_modules/@effect/platform-node/dist/Undici.js
for undici_js in $UNDICI_SHIMS; do
    if [ -f "$undici_js" ]; then
        if grep -q "OPENCODE_BUNDLER_SHIM" "$undici_js"; then
            echo "    $undici_js already regenerated"
            continue
        fi
        UNDICI_NAMES=$("$HOST_BUN" -e 'const u=require("undici");console.log(Object.keys(u).filter(k=>/^[A-Za-z_$][A-Za-z0-9_$]*$/.test(k)).join(" "))')
        UNDICI_TMP="${undici_js}.android-tmp"
        {
            echo "// OPENCODE_BUNDLER_SHIM: regenerated by opencode-termux build."
            echo "// Bun 1.3.2 miscompiles 'export * from \"undici\"' (a Bun built-in)"
            echo "// into a reference to a namespace binding it never emits."
            echo "import UndiciDefault from \"undici\";"
            echo "const Undici = UndiciDefault;"
            for undici_name in $UNDICI_NAMES; do
                if [ "$undici_name" != "default" ]; then
                    echo "export const $undici_name = Undici.$undici_name;"
                fi
            done
            echo "export default UndiciDefault;"
        } > "$UNDICI_TMP"
        mv -f "$UNDICI_TMP" "$undici_js"
        echo "    Regenerated $undici_js with explicit named exports"
    fi
done

# Run the TypeScript build script
# Copy it into the OpenCode tree so Bun can resolve @opentui/solid/bun-plugin
# from node_modules (Bun resolves bare imports relative to the script file's location)
echo ">>> Building OpenCode standalone binary..."
BUILD_SCRIPT="$REPO_ROOT/scripts/build-opencode-android.ts"
BUILD_SCRIPT_LOCAL="$OPENCODE_PKG/build-opencode-android.ts"
cp "$BUILD_SCRIPT" "$BUILD_SCRIPT_LOCAL"
cd "$OPENCODE_PKG"

OPENCODE_VERSION="$OPENCODE_VERSION" \
    ANDROID_BUN="$ANDROID_BUN" \
    OUTPUT_DIR="$DIST_DIR" \
    OPENCODE_DIR="$OPENCODE_PKG" \
    "$HOST_BUN" run "$BUILD_SCRIPT_LOCAL"

# Clean up copied script
rm -f "$BUILD_SCRIPT_LOCAL"

# Restore original @opentui/core-linux-x64 files
if [ ${#OPENTUI_BACKUPS[@]} -gt 0 ]; then
    echo ">>> Restoring original @opentui/core-linux-x64 files..."
    for backup_spec in "${OPENTUI_BACKUPS[@]}"; do
        orig="${backup_spec%%:*}"
        backup="${backup_spec##*:}"
        if [ -f "$backup" ]; then
            mv "$backup" "$orig"
        fi
    done
fi

# ============================================================
# Optional: build opencode-debug using bun-profile (unstripped)
# ============================================================
# bun-profile keeps DWARF symbols so Zig's panic handler prints
# file:line stack traces. Non-fatal: skip gracefully if absent.
ANDROID_DEBUG_BUN="$BUN_BUILD/bun-profile"
if [ -f "$ANDROID_DEBUG_BUN" ]; then
    echo ""
    echo ">>> Building OpenCode debug variant (bun-profile, unstripped)..."
    DEBUG_OUTPUT_DIR="$DIST_DIR/.debug-tmp"
    DEBUG_BINARY="$DIST_DIR/opencode-debug"

    # Re-patch @opentui/core-linux-x64 for the second build pass
    DEBUG_OPENTUI_BACKUPS=()
    for pkg_dir in "${OPENTUI_PACKAGES[@]}"; do
        so_file="$pkg_dir/libopentui.so"
        idx_file=""
        if [ -f "$pkg_dir/index.js" ]; then
            idx_file="$pkg_dir/index.js"
        elif [ -f "$pkg_dir/index.ts" ]; then
            idx_file="$pkg_dir/index.ts"
        fi
        if [ -f "$so_file" ]; then
            debug_backup="${so_file}.x64.debug-bak"
            cp "$so_file" "$debug_backup"
            cp "$ARM64_LIBOPENTUI" "$so_file"
            DEBUG_OPENTUI_BACKUPS+=("$so_file:$debug_backup")
        fi
        if [ -n "$idx_file" ] && [ -f "$idx_file" ]; then
            debug_idx_backup="${idx_file}.debug-bak"
            cp "$idx_file" "$debug_idx_backup"
            cat > "$idx_file" <<'IDXEOF'
const fs = require("fs");
const path = require("path");
function androidLibPath() {
  try {
    const next = path.join(path.dirname(process.execPath), "libopentui.so");
    if (fs.existsSync(next)) return next;
  } catch (e) {}
  return "/data/data/com.termux/files/usr/lib/libopentui.so";
}
module.exports = androidLibPath();
IDXEOF
            DEBUG_OPENTUI_BACKUPS+=("$idx_file:$debug_idx_backup")
        fi
    done

    cp "$BUILD_SCRIPT" "$BUILD_SCRIPT_LOCAL"
    cd "$OPENCODE_PKG"
    OPENCODE_VERSION="$OPENCODE_VERSION" \
        ANDROID_BUN="$ANDROID_DEBUG_BUN" \
        OUTPUT_DIR="$DEBUG_OUTPUT_DIR" \
        OPENCODE_DIR="$OPENCODE_PKG" \
        "$HOST_BUN" run "$BUILD_SCRIPT_LOCAL" && \
        mv "$DEBUG_OUTPUT_DIR/opencode" "$DEBUG_BINARY" && \
        echo "    Debug binary: $DEBUG_BINARY ($(du -h "$DEBUG_BINARY" | cut -f1))" || \
        echo "    WARNING: Debug variant build failed, skipping"

    rm -f "$BUILD_SCRIPT_LOCAL"
    rm -rf "$DEBUG_OUTPUT_DIR"

    # Restore @opentui/core-linux-x64 files after debug build
    if [ ${#DEBUG_OPENTUI_BACKUPS[@]} -gt 0 ]; then
        echo ">>> Restoring @opentui/core-linux-x64 files after debug build..."
        for backup_spec in "${DEBUG_OPENTUI_BACKUPS[@]}"; do
            orig="${backup_spec%%:*}"
            backup="${backup_spec##*:}"
            if [ -f "$backup" ]; then
                mv "$backup" "$orig"
            fi
        done
    fi
else
    echo ">>> bun-profile not found, skipping debug variant"
    echo "    (run 'ninja bun-profile' in the bun-build dir to enable it)"
fi

# Stage ARM64 libopentui.so for packaging. This MUST happen after the
# TypeScript build script because build-opencode-android.ts clears OUTPUT_DIR
# (which is DIST_DIR) at the start of its run.
mkdir -p "$DIST_DIR"
cp "$ARM64_LIBOPENTUI" "$DIST_DIR/libopentui.so"
echo ">>> Staged ARM64 libopentui.so for packaging"

# Stage ARM64 librust_pty_arm64.so for packaging if available.
# bun-pty ships a prebuilt ARM64 .so; make-packages.sh will include it so
# PTY features work on Android (Bun's /$bunfs/root/ paths are not intercepted).
RUST_PTY_ARM64_CANDIDATE=""
for candidate in \
    "$OPENCODE_SRC/node_modules/bun-pty/rust-pty/target/release/librust_pty_arm64.so" \
    "$OPENCODE_PKG/node_modules/bun-pty/rust-pty/target/release/librust_pty_arm64.so"
do
    if [ -f "$candidate" ]; then
        RUST_PTY_ARM64_CANDIDATE="$candidate"
        break
    fi
done
if [ -n "$RUST_PTY_ARM64_CANDIDATE" ] && is_android_shared_object "$RUST_PTY_ARM64_CANDIDATE"; then
    cp "$RUST_PTY_ARM64_CANDIDATE" "$DIST_DIR/librust_pty_arm64.so"
    echo ">>> Staged ARM64 librust_pty_arm64.so for packaging"
elif [ -n "$RUST_PTY_ARM64_CANDIDATE" ]; then
    rm -f "$DIST_DIR/librust_pty_arm64.so"
    echo ">>> WARNING: found ARM64 librust_pty_arm64.so, but it is linked for Linux/glibc; omitting from Android package"
else
    echo ">>> WARNING: librust_pty_arm64.so not found; PTY features may not work"
fi

# Verify output
OPENCODE_BINARY="$DIST_DIR/opencode"
if [ ! -f "$OPENCODE_BINARY" ]; then
    echo "ERROR: OpenCode binary not found at $OPENCODE_BINARY"
    exit 1
fi

echo ""
echo "=== OpenCode build complete ==="
echo "Binary: $OPENCODE_BINARY"
echo "Size: $(du -h "$OPENCODE_BINARY" | cut -f1)"
file "$OPENCODE_BINARY"
