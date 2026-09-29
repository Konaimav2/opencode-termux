#!/usr/bin/env bash
# Create distribution packages for OpenCode V2 (takes over the `opencode` command).
#
# Usage: ./scripts/make-packages-v2.sh
#
# Creates three package formats:
# 1. ZIP: opencode-${OPENCODE_V2_PKGVER}-android-aarch64.zip (standalone)
# 2. Pacman: opencode-${OPENCODE_V2_PKGVER}-1-aarch64.pkg.tar.xz (Termux pacman format)
# 3. Deb: opencode_${OPENCODE_V2_PKGVER}_aarch64.deb (Termux deb format)
#
# Package version tracks the opencode V2 *source* tag (OPENCODE_V2_PKGVER,
# default 2.0.19 — see scripts/env-v2.sh header for why NOT upstream's 1.0.1).
# Since 2.0.19 > 1.18.27, `pacman -U` / `dpkg -i` UPGRADE a v1 install in
# place: bin/opencode and libexec/opencode/opencode.bin are replaced.
# v1's lib/libopentui.so is left behind as a harmless orphan (v2 keeps its
# renderer private under libexec/opencode/).
#
# Package layout (all formats — v2 takes over the `opencode` command):
#   bin/opencode                        — wrapper: LD_PRELOAD libtagfix + lib paths, then execs real binary
#   libexec/opencode/opencode.bin       — real v2 ELF binary
#   libexec/opencode/libopentui.so      — opentui TUI renderer library (ARM64 Android)
#   libexec/opencode/libtagfix.so       — disables Android bionic TBI heap tagging at process start
#
# Repo sources: wrapper template is bin/opencode2 (bin/opencode stays the V1
# wrapper so the v1 line keeps building); the built binary is
# $DIST_DIR/opencode2.bin (from scripts/build-opencode2.sh).
#
# ZIP install (flat layout — wrapper resolves siblings via its own dir):
#   unzip opencode-...-android-aarch64.zip -d $PREFIX/bin/
#   chmod +x $PREFIX/bin/opencode $PREFIX/bin/opencode.bin

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

check_elf_aarch64 "$OPENCODE2_BINARY" "opencode.bin"
check_elf_aarch64 "$ARM64_LIBOPENTUI" "libopentui.so"
check_android_shared_object "$ARM64_LIBOPENTUI" "libopentui.so"

echo "=== Creating packages for opencode v${OPENCODE_V2_PKGVER} (V2 takes over 'opencode') ==="

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
#   unzip opencode-...-android-aarch64.zip -d $PREFIX/bin/
# drops wrapper, real binary, and libs together.
# The wrapper resolves siblings via its own dir.
echo ">>> Creating ZIP package..."
ZIP_NAME="opencode-${OPENCODE_V2_PKGVER}-android-aarch64.zip"
cp "$OPENCODE2_BINARY" "$PKG_DIR/opencode.bin"
cp "$WRAPPER_SCRIPT"  "$PKG_DIR/opencode"
cp "$ARM64_LIBOPENTUI" "$PKG_DIR/libopentui.so"
chmod 755 "$PKG_DIR/opencode" "$PKG_DIR/opencode.bin"
cd "$PKG_DIR"
zip -9 "$PKG_DIR/$ZIP_NAME" opencode opencode.bin libtagfix.so libopentui.so
echo "    Created $ZIP_NAME"

# ==========================================
# 2. Pacman package (Termux)
# ==========================================
echo ">>> Creating pacman package..."
PACMAN_STAGING="$PKG_DIR/pacman-staging"
PACMAN_USR="$PACMAN_STAGING/data/data/com.termux/files/usr"
mkdir -p "$PACMAN_USR/bin" "$PACMAN_USR/libexec/opencode"

cp "$WRAPPER_SCRIPT" "$PACMAN_USR/bin/opencode"
chmod 755 "$PACMAN_USR/bin/opencode"

cp "$OPENCODE2_BINARY" "$PACMAN_USR/libexec/opencode/opencode.bin"
chmod 755 "$PACMAN_USR/libexec/opencode/opencode.bin"

cp "$ARM64_LIBOPENTUI" "$PACMAN_USR/libexec/opencode/libopentui.so"
chmod 644 "$PACMAN_USR/libexec/opencode/libopentui.so"

cp "$TAGFIX_SO" "$PACMAN_USR/libexec/opencode/libtagfix.so"
chmod 644 "$PACMAN_USR/libexec/opencode/libtagfix.so"

# Create .PKGINFO
cat > "$PACMAN_STAGING/.PKGINFO" << EOF
pkgname = opencode
pkgver = ${OPENCODE_V2_PKGVER}-1
pkgdesc = OpenCode 2 AI coding assistant for Android/Termux (takes over the opencode command)
url = https://github.com/anomalyco/opencode
builddate = ${BUILD_DATE}
packager = opencode-termux
size = ${INSTALLED_SIZE}
arch = aarch64
license = MIT
depend = ripgrep
EOF

PACMAN_NAME="opencode-${OPENCODE_V2_PKGVER}-1-aarch64.pkg.tar.xz"
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
mkdir -p "$DEB_USR/bin" "$DEB_USR/libexec/opencode"
mkdir -p "$DEB_STAGING/DEBIAN"

cp "$WRAPPER_SCRIPT" "$DEB_USR/bin/opencode"
chmod 755 "$DEB_USR/bin/opencode"

cp "$OPENCODE2_BINARY" "$DEB_USR/libexec/opencode/opencode.bin"
chmod 755 "$DEB_USR/libexec/opencode/opencode.bin"

cp "$ARM64_LIBOPENTUI" "$DEB_USR/libexec/opencode/libopentui.so"
chmod 644 "$DEB_USR/libexec/opencode/libopentui.so"

cp "$TAGFIX_SO" "$DEB_USR/libexec/opencode/libtagfix.so"
chmod 644 "$DEB_USR/libexec/opencode/libtagfix.so"

# Create control file
cat > "$DEB_STAGING/DEBIAN/control" << EOF
Package: opencode
Version: ${OPENCODE_V2_PKGVER}
Architecture: aarch64
Maintainer: Guy Sheffer <guysoft@gmail.com>
Installed-Size: ${INSTALLED_SIZE}
Depends: ripgrep
Section: utils
Priority: optional
Homepage: https://github.com/anomalyco/opencode
Description: OpenCode 2 AI coding assistant for Android/Termux
 OpenCode v2 CLI with the Android OpenTUI renderer. Takes over the
 `opencode` command: installing over a v1 package upgrades it in place
 (2.0.19 > 1.18.27). The v1 lib/libopentui.so stays behind as a harmless
 orphan; v2 keeps its renderer private under libexec/opencode/.
EOF

DEB_NAME="opencode_${OPENCODE_V2_PKGVER}_aarch64.deb"

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
echo "Install on Termux (upgrades a v1 install in place):"
echo "  Pacman: pacman -U $PACMAN_NAME"
echo "  Deb:    dpkg -i $DEB_NAME"
echo ""
echo "  Standalone (zip) — installs wrapper + binary + libs into bin/:"
echo "    unzip $ZIP_NAME -d \$PREFIX/bin/"
echo "    chmod +x \$PREFIX/bin/opencode \$PREFIX/bin/opencode.bin"
echo ""
