#!/usr/bin/env bash
# Build libopentui.so (v2 line) for Android aarch64.
#
# Usage: ./scripts/build-opentui-v2.sh
#
# OpenCode v2's TUI renderer (@opentui/core 0.5.10) uses a native Zig library.
# The upstream build targets aarch64-linux (musl), which fails on Android
# because getauxval cannot be resolved. We apply
# patches/opentui/v2-0.5.10-android-termux.patch (bionic sysroot + pthread/m
# guards) and build for aarch64-linux-android with Zig 0.16.0.
#
# Requires: Zig 0.16.0, Android NDK (see scripts/env-v2.sh).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env-v2.sh"

ZIG_BIN="${ZIG_BIN:-zig}"

echo "=== Building libopentui.so (v2, opentui v${OPENTUI_VERSION}) for Android aarch64 ==="

# Clone opentui at the pinned tag if needed, else ensure the tag is checked out.
SRC="${OPENTUI_V2_SRC}"
mkdir -p "$WORK_DIR"
if [ ! -d "$SRC/.git" ]; then
    echo ">>> Cloning opentui (tag v${OPENTUI_VERSION})..."
    git clone --depth 1 --branch "v${OPENTUI_VERSION}" https://github.com/anomalyco/opentui.git "$SRC"
else
    echo ">>> opentui source exists at $SRC"
    cd "$SRC"
    CURRENT="$(git describe --tags --exact-match 2>/dev/null || git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    if [ "$CURRENT" != "v${OPENTUI_VERSION}" ]; then
        echo "    Checking out v${OPENTUI_VERSION} (was $CURRENT)..."
        git fetch --tags origin "v${OPENTUI_VERSION}" 2>/dev/null || true
        git checkout --force "v${OPENTUI_VERSION}"
    fi
fi

# Apply the Android patch with a loud gate: fail unless the patch applies
# cleanly or is already applied (same pattern as scripts/build-opencode.sh).
OPENTUI_V2_PATCH="$REPO_ROOT/patches/opentui/v2-0.5.10-android-termux.patch"
if [ ! -f "$OPENTUI_V2_PATCH" ]; then
    echo "ERROR: $OPENTUI_V2_PATCH not found"
    exit 1
fi
echo ">>> Applying opentui v2 Android patch (patches/opentui/v2-0.5.10-android-termux.patch)..."
cd "$SRC"
if git apply --check "$OPENTUI_V2_PATCH" 2>/dev/null; then
    git apply "$OPENTUI_V2_PATCH"
    echo "    Patch applied successfully"
elif git apply --check --reverse "$OPENTUI_V2_PATCH" 2>/dev/null; then
    echo "    Patch already applied, skipping"
else
    echo "ERROR: opentui v2 Android patch does not apply cleanly to v${OPENTUI_VERSION}"
    echo "       Regenerate patches/opentui/v2-0.5.10-android-termux.patch against this tag."
    exit 1
fi

# Stage the merged bionic sysroot: NDK usr/include with the arch-specific
# subdir flattened in, plus nullability shims for translate-c (Zig cannot
# parse clang _Nullable/_Nonnull annotations on array params).
echo ">>> Staging merged bionic sysroot..."
if [ ! -d "$NDK_SYSROOT/usr/include" ]; then
    echo "ERROR: NDK sysroot includes not found at $NDK_SYSROOT/usr/include"
    echo "       Check ANDROID_NDK_HOME=$ANDROID_NDK_HOME"
    exit 1
fi
rm -rf "$BIONIC_SYSROOT_INC"
mkdir -p "$BIONIC_SYSROOT_INC"
cp -a "$NDK_SYSROOT/usr/include/." "$BIONIC_SYSROOT_INC/"
cp -a "$NDK_SYSROOT/usr/include/aarch64-linux-android/." "$BIONIC_SYSROOT_INC/"
mkdir -p "$BIONIC_SYSROOT_INC/__opentui"
cat > "$BIONIC_SYSROOT_INC/__opentui/miniaudio_shimmed.h" <<'EOF'
#define _Nullable
#define _Nonnull
#include "../miniaudio.h"
EOF
cat > "$BIONIC_SYSROOT_INC/__opentui/Yoga_shimmed.h" <<'EOF'
#define _Nullable
#define _Nonnull
#include "../yoga/yoga/Yoga.h"
EOF

# Zig libc config pointing at the NDK bionic sysroot (API level = $ANDROID_API,
# our floor — NOT upstream's hardcoded 29).
cat > "$ZIG_LIBC" <<EOF
include_dir=$BIONIC_SYSROOT_INC
sys_include_dir=$BIONIC_SYSROOT_INC
crt_dir=$NDK_SYSROOT/usr/lib/aarch64-linux-android/$ANDROID_API
msvc_lib_dir=
kernel32_lib_dir=
gcc_dir=
EOF

echo ">>> Building with Zig (target: aarch64-linux-android, optimize: ReleaseSafe)..."
export ANDROID_NDK_HOME BIONIC_SYSROOT_INC ZIG_LIBC
cd "$SRC/packages/native"
"$ZIG_BIN" build -Dlibrary-target=aarch64-linux-android -Doptimize=ReleaseSafe
cp "lib/aarch64-linux-android/libopentui.so" "$OPENTUI_LIB"

echo ""
echo "=== libopentui.so (v2) build complete ==="
echo "Output: $OPENTUI_LIB"
echo "Size: $(du -h "$OPENTUI_LIB" | cut -f1)"
file "$OPENTUI_LIB"
