#!/usr/bin/env bash
# Environment variables for building OpenCode V2 (opencode2) for Android aarch64.
# Source this file before running any v2 build scripts:
#   source scripts/env-v2.sh
#
# V2 line differences vs scripts/env.sh (v1):
#   - Host AND target Bun are both 1.4.2. The v2 binary is produced with the
#     official `bun build --target=opencode-linux-arm64-android` — NO custom
#     Bun/WebKit rebuild on the v2 line (no build-bun.sh, no build-webkit.sh).
#     The Android target entry itself comes from our
#     patches/opencode2/android-target.patch (no public opencode source
#     ships it) applied by scripts/build-opencode2.sh.
#   - opentui is pinned to 0.5.12 (the version opencode v2 depends on).
#   - Zig is 0.16.0: the v2 opentui Android patch needs it. Kept in the
#     separate ZIG_V2_VERSION variable so it can never collide with v1's
#     ZIG_VERSION=0.15.2.
#   - ANDROID_API stays 24 (our floor), NOT upstream's 29.
#   - All work happens under build-v2/ so the v1 build/ tree is never touched.
#
# Package version choice: OPENCODE_V2_PKGVER=2.0.19 tracks the opencode V2
# *source* tag (OPENCODE_V2_REF=v2.0.19, minus the leading `v`). We do NOT
# follow upstream's `opencode2-1.0.1` package naming — that 1.0.1 is a
# release-channel counter that collides confusingly with v1's 1.x versions.
# Tracking the source tag keeps `opencode --version` and the package
# version in agreement.

set -euo pipefail

export REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Versions
export BUN_VERSION="${BUN_VERSION:-1.4.2}"
export OPENTUI_VERSION="${OPENTUI_VERSION:-0.5.12}"
export OPENCODE_V2_REF="${OPENCODE_V2_REF:-v2.0.19}"
export OPENCODE_V2_PKGVER="${OPENCODE_V2_PKGVER:-2.0.19}"
export OPENCODE_CHANNEL="${OPENCODE_CHANNEL:-android-termux}"
export ZIG_V2_VERSION="${ZIG_V2_VERSION:-0.16.0}"
export ANDROID_API="${ANDROID_API:-24}"

# Android NDK
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-/opt/android-ndk}"
export ANDROID_ABI=arm64-v8a
export ANDROID_ARCH=aarch64
export ANDROID_TRIPLE="aarch64-linux-android"
export ANDROID_TRIPLE_API="${ANDROID_TRIPLE}${ANDROID_API}"

# NDK toolchain paths
export NDK_TOOLCHAIN="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64"
export NDK_SYSROOT="${NDK_TOOLCHAIN}/sysroot"
export ANDROID_CC="${NDK_TOOLCHAIN}/bin/${ANDROID_TRIPLE_API}-clang"
export ANDROID_CXX="${NDK_TOOLCHAIN}/bin/${ANDROID_TRIPLE_API}-clang++"
export ANDROID_AR="${NDK_TOOLCHAIN}/bin/llvm-ar"
export ANDROID_RANLIB="${NDK_TOOLCHAIN}/bin/llvm-ranlib"
export ANDROID_STRIP="${NDK_TOOLCHAIN}/bin/llvm-strip"
export ANDROID_NM="${NDK_TOOLCHAIN}/bin/llvm-nm"
export ANDROID_LD="${NDK_TOOLCHAIN}/bin/ld.lld"

# Host Bun drives `bun install` and the opencode2 `bun build`.
# scripts/build-opencode2.sh installs exactly $BUN_VERSION when the
# current bun differs (same pattern as .github/workflows/build.yml).
export HOST_BUN="${HOST_BUN:-bun}"
export ZIG_BIN="${ZIG_BIN:-zig}"

# Build directories (all relative to REPO_ROOT; build-v2/ keeps clear of v1 build/)
export WORK_DIR="${WORK_DIR:-${REPO_ROOT}/build-v2}"
export OPENTUI_V2_SRC="${OPENTUI_V2_SRC:-${WORK_DIR}/opentui-v2-src}"
export OPENCODE_V2_SRC="${OPENCODE_V2_SRC:-${WORK_DIR}/opencode-v2-src}"
# Optional: reuse an existing anomalyco/opencode checkout instead of cloning
# (e.g. OPENCODE_V2_WORKTREE=~/workspace/opencode/oc-v2).
export OPENCODE_V2_WORKTREE="${OPENCODE_V2_WORKTREE:-}"
export DIST_DIR="${DIST_DIR:-${WORK_DIR}/dist}"
export PACKAGE_DIR="${PACKAGE_DIR:-${WORK_DIR}/packages}"

# Bionic sysroot staging for the opentui zig build (see build-opentui-v2.sh)
export BIONIC_SYSROOT_INC="${WORK_DIR}/bionic-include"
export ZIG_LIBC="${WORK_DIR}/bionic-libc.txt"
export OPENTUI_LIB="${WORK_DIR}/libopentui.so"

# Number of parallel jobs (can be overridden for low-RAM machines)
export JOBS="${JOBS:-$(nproc)}"

echo "=== OpenCode V2 (opencode2) Android Build Environment ==="
echo "Repo root:     ${REPO_ROOT}"
echo "Work dir:      ${WORK_DIR}"
echo "NDK:           ${ANDROID_NDK_HOME}"
echo "API Level:     ${ANDROID_API}"
echo "Target:        ${ANDROID_TRIPLE}"
echo "Bun version:   ${BUN_VERSION} (host and target)"
echo "opentui ver:   ${OPENTUI_VERSION}"
echo "opencode ref:  ${OPENCODE_V2_REF} (pkgver ${OPENCODE_V2_PKGVER})"
echo "Zig (v2):      ${ZIG_V2_VERSION}"
echo "Jobs:          ${JOBS}"
echo "=========================================================="
