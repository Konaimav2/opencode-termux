#!/usr/bin/env bash
# Create distribution packages for OpenCode V2 (opencode2) for Android.
#
# Usage: ./scripts/make-packages-v2.sh
#
# Creates three package formats:
# 1. ZIP: opencode2-${OPENCODE_V2_PKGVER}-android-aarch64.zip (standalone)
# 2. Pacman: opencode2-${OPENCODE_V2_PKGVER}-1-aarch64.pkg.tar.xz (Termux pacman format)
# 3. Deb: opencode2_${OPENCODE_V2_PKGVER}_aarch64.deb (Termux deb format)
#
# Package version tracks the opencode V2 *source* tag (OPENCODE_V2_PKGVER,
# default 2.0.18 — see scripts/env-v2.sh header for why NOT upstream's 1.0.1).
#
# Package layout (all formats — side-by-side with the v1 "opencode" package):
#   bin/opencode2                       — wrapper: LD_PRELOAD libtagfix + lib paths, then execs real binary
#   libexec/opencode2/opencode2.bin     — real opencode2 ELF binary
#   libexec/opencode2/libopentui.so     — opentui TUI renderer library (ARM64 Android)
#   libexec/opencode2/libtagfix.so      — disables Android bionic TBI heap tagging at process start
#
# Nothing is ever installed under lib/ (v1 owns lib/libtagfix.so and
# lib/libopentui.so there), so v1 and v2 install side by side.
#
# ZIP install (flat layout — wrapper resolves siblings via its own dir):
#   unzip opencode2-...-android-aarch64.zip -d $PREFIX/bin/
#   chmod +x $PREFIX/bin/opencode2 $PREFIX/bin/opencode2.bin

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env-v2.sh"

OPENCODE2_BINARY="$DIST_DIR/opencode2.bin"
WRAPPER_SCRIPT="$REPO_ROOT/bin/opencode2"
TAGFIX_SRC="$REPO_ROOT/src/libtagfix.c"
PKG_DIR="${PACKAGE_DIR:-$WORK_DIR/packages}"
ARM64_LIBOPENTUI="$OPENTUI_LIB"

if [ ! -f "$OPENCODE2_BINARY" ]; then
    echo "ERROR: opencode2 binary not found at $OPENCODE2_BINARY"
    echo "       Run scripts/build-opencode2.sh first."
    exit 1
fi

if [ ! -f "$WRAPPER_SCRIPT" ]; then
    echo "ERROR: Wrapper script not found at $WRAPPER_SCRIPT"
    exit 1
fi

if [ ! -f "$TAGFIX_SRC" ]; then
    echo "ERROR: libtagfix.c not found at $TAGFIX_SRC"
    exit 1
fi

if [ ! -f "$ARM64_LIBOPENTUI" ]; then
    echo "ERROR: ARM64 libopentui.so not found at $ARM64_LIBOPENTUI"
    echo "       Run scripts/build-opentui-v2.sh first."
    exit 1
fi

# Verify the shipped native libraries are actually AArch64.
# e_machine for AArch64 is 0xb7 (little-endian at ELF offset 18).
check_elf_aarch64() {
    local file="$1"
    local name="$2"
    if [ ! -f "$file" ]; then
        echo "ERROR: $name not found at $file"
        exit 1
    fi
    local machine
    machine=$(od -An -t x1 -j 18 -N 2 "$file" | tr -d ' ')
    if [ "$machine" != "b700" ]; then
        echo "ERROR: $name is not AArch64 (e_machine=$machine)"
        exit 1
    fi
    echo "    Verified $name is AArch64"
}

check_android_shared_object() {
    local file="$1"
    local name="$2"
    local needed
    needed=$(readelf -d "$file" 2>/dev/null | grep 'Shared library:' || true)
    if echo "$needed" | grep -Eq 'libc\.so\.6|libpthread\.so\.0|libdl\.so\.2|libutil\.so\.1'; then
        echo "ERROR: $name is linked against Linux/glibc libraries, not Android/Bionic:"
        echo "$needed"
        exit 1
    fi
    echo "    Verified $name has Android-compatible dynamic dependencies"
}

check_elf_aarch64 "$OPENCODE2_BINARY" "opencode2.bin"
check_elf_aarch64 "$ARM64_LIBOPENTUI" "libopentui.so"
check_android_shared_object "$ARM64_LIBOPENTUI" "libopentui.so"

echo "=== Creating packages for opencode2 v${OPENCODE_V2_PKGVER} ==="

BINARY_SIZE=$(stat -c%s "$OPENCODE2_BINARY")
BUILD_DATE=$(date +%s)

# Clean up
rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR"

# ==========================================
# Compile libtagfix.so (Android aarch64)
# ==========================================
echo ">>> Compiling libtagfix.so..."
TAGFIX_SO="$PKG_DIR/libtagfix.so"
"$ANDROID_CC" -shared -fPIC -O2 -o "$TAGFIX_SO" "$TAGFIX_SRC"
echo "    Compiled $(stat -c%s "$TAGFIX_SO") bytes"
check_elf_aarch64 "$TAGFIX_SO" "libtagfix.so"

TAGFIX_SIZE=$(stat -c%s "$TAGFIX_SO")
LIBOPENTUI_SIZE=$(stat -c%s "$ARM64_LIBOPENTUI")

INSTALLED_SIZE=$(( (BINARY_SIZE + TAGFIX_SIZE + LIBOPENTUI_SIZE + 8192) / 1024 ))  # rough kB estimate

# ==========================================
# 1. ZIP package (flat layout)
# ==========================================
# All files are placed at the top level so a single
#   unzip opencode2-...-android-aarch64.zip -d $PREFIX/bin/
# drops wrapper, real binary, and libs together.
# The wrapper resolves siblings via its own dir.
echo ">>> Creating ZIP package..."
ZIP_NAME="opencode2-${OPENCODE_V2_PKGVER}-android-aarch64.zip"
cp "$OPENCODE2_BINARY" "$PKG_DIR/opencode2.bin"
cp "$WRAPPER_SCRIPT"  "$PKG_DIR/opencode2"
cp "$ARM64_LIBOPENTUI" "$PKG_DIR/libopentui.so"
chmod 755 "$PKG_DIR/opencode2" "$PKG_DIR/opencode2.bin"
cd "$PKG_DIR"
zip -9 "$PKG_DIR/$ZIP_NAME" opencode2 opencode2.bin libtagfix.so libopentui.so
echo "    Created $ZIP_NAME"

# ==========================================
# 2. Pacman package (Termux)
# ==========================================
echo ">>> Creating pacman package..."
PACMAN_STAGING="$PKG_DIR/pacman-staging"
PACMAN_USR="$PACMAN_STAGING/data/data/com.termux/files/usr"
mkdir -p "$PACMAN_USR/bin" "$PACMAN_USR/libexec/opencode2"

cp "$WRAPPER_SCRIPT" "$PACMAN_USR/bin/opencode2"
chmod 755 "$PACMAN_USR/bin/opencode2"

cp "$OPENCODE2_BINARY" "$PACMAN_USR/libexec/opencode2/opencode2.bin"
chmod 755 "$PACMAN_USR/libexec/opencode2/opencode2.bin"

cp "$ARM64_LIBOPENTUI" "$PACMAN_USR/libexec/opencode2/libopentui.so"
chmod 644 "$PACMAN_USR/libexec/opencode2/libopentui.so"

cp "$TAGFIX_SO" "$PACMAN_USR/libexec/opencode2/libtagfix.so"
chmod 644 "$PACMAN_USR/libexec/opencode2/libtagfix.so"

# Create .PKGINFO
cat > "$PACMAN_STAGING/.PKGINFO" << EOF
pkgname = opencode2
pkgver = ${OPENCODE_V2_PKGVER}-1
pkgdesc = OpenCode 2 AI coding assistant for Android/Termux
url = https://github.com/anomalyco/opencode
builddate = ${BUILD_DATE}
packager = opencode-termux
size = ${INSTALLED_SIZE}
arch = aarch64
license = MIT
depend = ripgrep
EOF

PACMAN_NAME="opencode2-${OPENCODE_V2_PKGVER}-1-aarch64.pkg.tar.xz"
cd "$PACMAN_STAGING"
tar cf - .PKGINFO data | xz -9 > "$PKG_DIR/$PACMAN_NAME"
echo "    Created $PACMAN_NAME"

# ==========================================
# 3. Deb package (Termux format)
# ==========================================
echo ">>> Creating deb package..."
DEB_STAGING="$PKG_DIR/deb-staging"
# Note: the extra leading 'data/' under deb-staging is intentional.
# The packaging step does: cd deb-staging/data && tar ... data
# so the data.tar.gz contains data/data/com.termux/... which dpkg
# extracts to /data/data/com.termux/... (the real Termux prefix).
DEB_USR="$DEB_STAGING/data/data/data/com.termux/files/usr"
mkdir -p "$DEB_USR/bin" "$DEB_USR/libexec/opencode2"
mkdir -p "$DEB_STAGING/DEBIAN"

cp "$WRAPPER_SCRIPT" "$DEB_USR/bin/opencode2"
chmod 755 "$DEB_USR/bin/opencode2"

cp "$OPENCODE2_BINARY" "$DEB_USR/libexec/opencode2/opencode2.bin"
chmod 755 "$DEB_USR/libexec/opencode2/opencode2.bin"

cp "$ARM64_LIBOPENTUI" "$DEB_USR/libexec/opencode2/libopentui.so"
chmod 644 "$DEB_USR/libexec/opencode2/libopentui.so"

cp "$TAGFIX_SO" "$DEB_USR/libexec/opencode2/libtagfix.so"
chmod 644 "$DEB_USR/libexec/opencode2/libtagfix.so"

# Create control file
cat > "$DEB_STAGING/DEBIAN/control" << EOF
Package: opencode2
Version: ${OPENCODE_V2_PKGVER}
Architecture: aarch64
Maintainer: Guy Sheffer <guysoft@gmail.com>
Installed-Size: ${INSTALLED_SIZE}
Depends: ripgrep
Section: utils
Priority: optional
Homepage: https://github.com/anomalyco/opencode
Description: OpenCode 2 AI coding assistant for Android/Termux
 OpenCode v2 CLI (opencode2) with the Android OpenTUI renderer.
 Installs alongside the v1 opencode package: all v2 files live under
 bin/opencode2 and libexec/opencode2/, never under shared lib/.
EOF

DEB_NAME="opencode2_${OPENCODE_V2_PKGVER}_aarch64.deb"

# Build deb manually (dpkg-deb may not be available)
cd "$DEB_STAGING/data"
tar czf "$DEB_STAGING/data.tar.gz" data
cd "$DEB_STAGING/DEBIAN"
tar czf "$DEB_STAGING/control.tar.gz" control
echo "2.0" > "$DEB_STAGING/debian-binary"
cd "$DEB_STAGING"
ar rc "$PKG_DIR/$DEB_NAME" debian-binary control.tar.gz data.tar.gz
echo "    Created $DEB_NAME"

# ==========================================
# Summary
# ==========================================
echo ""
echo "=== Packages created ==="
echo ""
ls -lh "$PKG_DIR"/*.{zip,xz,deb} 2>/dev/null
echo ""
echo "Install on Termux:"
echo "  Pacman: pacman -U $PACMAN_NAME"
echo "  Deb:    dpkg -i $DEB_NAME"
echo ""
echo "  Standalone (zip) — installs wrapper + binary + libs into bin/:"
echo "    unzip $ZIP_NAME -d \$PREFIX/bin/"
echo "    chmod +x \$PREFIX/bin/opencode2 \$PREFIX/bin/opencode2.bin"
echo ""
