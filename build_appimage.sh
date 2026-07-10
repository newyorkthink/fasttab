#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

ARCH="$(uname -m)"
if [[ "$ARCH" != "x86_64" ]]; then
  echo "FastTab AppImage currently supports x86_64 only (detected: $ARCH)." >&2
  exit 1
fi
export ARCH

VERSION="$(tr -d '[:space:]' < VERSION)"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Invalid VERSION value: $VERSION" >&2
  exit 1
fi

export APPNAME="fasttab"
export STARTUPWMCLASS="FastTab"
export ICON="$ROOT_DIR/packaging/fasttab.svg"
export DESKTOP="$ROOT_DIR/packaging/fasttab.desktop"
export OUTPATH="$ROOT_DIR/dist"
export OUTNAME="FastTab-${VERSION}-x86_64.AppImage"
export DEPLOY_OPENGL=1

rm -rf AppDir dist
mkdir -p dist

if ! command -v yay >/dev/null 2>&1; then
  echo "This build script requires yay (the CI workflow provides it)." >&2
  exit 1
fi

if ! command -v quick-sharun >/dev/null 2>&1; then
  echo "quick-sharun was not found. Run this script inside the AnyLinux/Sharun build environment." >&2
  exit 1
fi

# Base packaging toolchain, matching the AnyLinux quick-sharun builders.
yay -S --needed --noconfirm \
  gcc \
  base-devel \
  git \
  curl \
  wget \
  tar \
  xz \
  binutils \
  patchelf \
  coreutils \
  appstream-glib \
  desktop-file-utils \
  util-linux \
  zsync \
  file \
  pkgconf \
  cmake \
  xorg-server-xvfb

# FastTab build and runtime dependencies. libX11-xcb.so is provided by libx11 on Arch.
yay -S --needed --noconfirm \
  alsa-lib \
  mesa \
  libglvnd \
  wayland \
  libx11 \
  libxcb \
  xcb-util \
  xcb-util-image \
  xcb-util-keysyms \
  libxcomposite \
  libxdamage \
  libxext \
  libxfixes \
  libxi \
  libxinerama \
  libxkbcommon \
  libxkbcommon-x11 \
  libxrandr \
  libxcursor \
  glfw-x11

ZIG_VERSION="0.14.0"
ZIG_DIR="/tmp/zig-linux-x86_64-${ZIG_VERSION}"
if [[ ! -x "$ZIG_DIR/zig" ]]; then
  ZIG_ARCHIVE="/tmp/zig-linux-x86_64-${ZIG_VERSION}.tar.xz"
  curl --fail --location --retry 3 \
    "https://ziglang.org/download/${ZIG_VERSION}/zig-linux-x86_64-${ZIG_VERSION}.tar.xz" \
    --output "$ZIG_ARCHIVE"
  rm -rf "$ZIG_DIR"
  tar -xf "$ZIG_ARCHIVE" -C /tmp
fi

./setup.sh
"$ZIG_DIR/zig" build test
"$ZIG_DIR/zig" build -Doptimize=ReleaseSafe -Dcpu=baseline

test -x zig-out/bin/fasttab
install -Dm755 zig-out/bin/fasttab /usr/local/bin/fasttab

desktop-file-validate "$DESKTOP"
quick-sharun /usr/local/bin/fasttab
quick-sharun --make-appimage

APPIMAGE="$OUTPATH/$OUTNAME"
test -s "$APPIMAGE"
chmod +x "$APPIMAGE"

cp zig-out/bin/fasttab "$OUTPATH/fasttab-x86_64"
chmod +x "$OUTPATH/fasttab-x86_64"
sha256sum "$APPIMAGE" > "$APPIMAGE.sha256"
sha256sum "$OUTPATH/fasttab-x86_64" > "$OUTPATH/fasttab-x86_64.sha256"

printf 'Created:\n'
find "$OUTPATH" -maxdepth 1 -type f -printf '  %f (%s bytes)\n' | sort
