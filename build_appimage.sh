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
export UPINFO="gh-releases-zsync|newyorkthink|fasttab|latest|FastTab-*-x86_64.AppImage.zsync"

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

# Minimal packaging toolchain required by quick-sharun and the Zig build.
yay -S --needed --noconfirm \
  gcc \
  git \
  curl \
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
  pkgconf

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

# Start the bundled daemon normally. A second FastTab instance exits immediately
# instead of terminating the already-running daemon.
awk '
$0 == "set -- \"$TO_LAUNCH\" \"$@\"" {
  print "if [ \"${TO_LAUNCH##*/}\" = \"fasttab\" ]; then"
  print "        set -- daemon \"$@\""
  print "fi"
  print ""
}
{ print }
' AppDir/AppRun.sh > AppDir/AppRun.sh.new
mv AppDir/AppRun.sh.new AppDir/AppRun.sh
chmod +x AppDir/AppRun.sh
grep -Fq 'set -- daemon "$@"' AppDir/AppRun.sh

quick-sharun --make-appimage

APPIMAGE="$OUTPATH/$OUTNAME"
test -s "$APPIMAGE"
chmod +x "$APPIMAGE"

# uruntime otherwise waits several seconds after Ctrl+C while checking whether
# the mounted image directory is still in use. Disable that polling delay.
"$APPIMAGE" --appimage-addenvs 'REUSE_CHECK_DELAY=0'
"$APPIMAGE" --appimage-envs | grep -Fxq 'REUSE_CHECK_DELAY=0'

# quick-sharun creates zsync metadata before the runtime environment is patched.
# Regenerate it so the zsync hashes match the final AppImage bytes.
rm -f "$APPIMAGE.zsync"
zsyncmake -u "$OUTNAME" -o "$APPIMAGE.zsync" "$APPIMAGE"

rm -f "$OUTPATH/appinfo"

cp zig-out/bin/fasttab "$OUTPATH/fasttab-x86_64"
chmod +x "$OUTPATH/fasttab-x86_64"

(
  cd "$OUTPATH"
  sha256sum "$OUTNAME" > "$OUTNAME.sha256"
  sha256sum fasttab-x86_64 > fasttab-x86_64.sha256
)

printf 'Created:\n'
find "$OUTPATH" -maxdepth 1 -type f -printf '  %f (%s bytes)\n' | sort
