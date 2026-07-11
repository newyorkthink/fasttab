#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

BUILD_APPIMAGE=1
BUILD_NATIVE_PACKAGES=1
case "${1:-}" in
  "") ;;
  --appimage-only) BUILD_NATIVE_PACKAGES=0 ;;
  --native-only) BUILD_APPIMAGE=0 ;;
  *) echo "Usage: $0 [--appimage-only|--native-only]" >&2; exit 2 ;;
esac

VERSION="$(tr -d '[:space:]' < VERSION)"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Invalid VERSION value: $VERSION" >&2
  exit 1
fi

case "$(uname -m)" in
  x86_64)
    APPIMAGE_ARCH="x86_64"
    DEB_ARCH="amd64"
    RPM_ARCH="x86_64"
    ;;
  aarch64|arm64)
    APPIMAGE_ARCH="aarch64"
    DEB_ARCH="arm64"
    RPM_ARCH="aarch64"
    ;;
  *)
    echo "Unsupported architecture: $(uname -m). FastTab packages support x86_64 and aarch64." >&2
    exit 1
    ;;
esac

for command in zig curl tar make cc install rsvg-convert desktop-file-validate sha256sum; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Error: required command not found: $command" >&2
    exit 1
  fi
done
if (( BUILD_APPIMAGE )); then
  for command in quick-sharun zsyncmake; do
    if ! command -v "$command" >/dev/null 2>&1; then
      echo "Error: required AppImage command not found: $command" >&2
      exit 1
    fi
  done
fi
if (( BUILD_NATIVE_PACKAGES )); then
  for command in dpkg-deb rpmbuild; do
    if ! command -v "$command" >/dev/null 2>&1; then
      echo "Error: required packaging command not found: $command" >&2
      exit 1
    fi
  done
fi

OUT_DIR="$ROOT_DIR/dist"
PACKAGE_ROOT="$ROOT_DIR/package-root"
RPM_TOP="$ROOT_DIR/rpmbuild"
rm -rf "$OUT_DIR" "$PACKAGE_ROOT" "$RPM_TOP" AppDir
mkdir -p "$OUT_DIR"

./setup.sh
zig build test
zig build -Doptimize=ReleaseSafe -Dcpu=baseline
test -x zig-out/bin/fasttab

desktop-file-validate packaging/fasttab.desktop

generate_icon_tree() {
  local root=$1
  local size

  install -Dm644 packaging/fasttab.desktop "$root/usr/share/applications/fasttab.desktop"
  install -Dm644 packaging/fasttab.svg "$root/usr/share/icons/hicolor/scalable/apps/fasttab.svg"

  for size in 16 32 64 128 256; do
    local icon_dir="$root/usr/share/icons/hicolor/${size}x${size}/apps"
    mkdir -p "$icon_dir"
    rsvg-convert -w "$size" -h "$size" packaging/fasttab.svg -o "$icon_dir/fasttab.png"
  done

  install -Dm644 "$root/usr/share/icons/hicolor/256x256/apps/fasttab.png" \
    "$root/usr/share/pixmaps/fasttab.png"
}

install_package_docs() {
  local root=$1

  install -Dm644 README.md "$root/usr/share/doc/fasttab/README.md"
  install -Dm644 README.zh-CN.md "$root/usr/share/doc/fasttab/README.zh-CN.md"
  install -Dm644 LICENSE.md "$root/usr/share/doc/fasttab/LICENSE.md"
}

create_package_root() {
  rm -rf "$PACKAGE_ROOT"
  install -Dm755 zig-out/bin/fasttab "$PACKAGE_ROOT/usr/bin/fasttab"
  generate_icon_tree "$PACKAGE_ROOT"
  install_package_docs "$PACKAGE_ROOT"
}

build_appimage() {
  export ARCH="$APPIMAGE_ARCH"
  export APPNAME="fasttab"
  export STARTUPWMCLASS="FastTab"
  export ICON="$ROOT_DIR/packaging/fasttab.svg"
  export DESKTOP="$ROOT_DIR/packaging/fasttab.desktop"
  export OUTPATH="$OUT_DIR"
  export OUTNAME="FastTab-${VERSION}-${APPIMAGE_ARCH}.AppImage"
  export DEPLOY_OPENGL=1
  export STRACE_MODE=0
  export UPINFO="gh-releases-zsync|newyorkthink|fasttab|latest|FastTab-*-${APPIMAGE_ARCH}.AppImage.zsync"

  quick-sharun "$ROOT_DIR/zig-out/bin/fasttab"

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

  generate_icon_tree "$ROOT_DIR/AppDir"
  install_package_docs "$ROOT_DIR/AppDir"
  install -Dm644 packaging/fasttab.svg AppDir/fasttab.svg
  ln -sfn fasttab.svg AppDir/.DirIcon

  quick-sharun --make-appimage

  local appimage="$OUT_DIR/$OUTNAME"
  test -s "$appimage"
  chmod +x "$appimage"

  "$appimage" --appimage-addenvs 'REUSE_CHECK_DELAY=0'
  "$appimage" --appimage-envs | grep -Fxq 'REUSE_CHECK_DELAY=0'

  rm -f "$appimage.zsync"
  zsyncmake -u "$OUTNAME" -o "$appimage.zsync" "$appimage"
  rm -f "$OUT_DIR/appinfo"

  (
    cd "$OUT_DIR"
    sha256sum "$OUTNAME" > "$OUTNAME.sha256"
  )
}

build_deb() {
  local deb_root="$ROOT_DIR/deb-root"
  local deb_name="fasttab_${VERSION}_${DEB_ARCH}.deb"
  rm -rf "$deb_root"
  cp -a "$PACKAGE_ROOT" "$deb_root"
  mkdir -p "$deb_root/DEBIAN"

  local installed_size
  installed_size="$(du -sk "$PACKAGE_ROOT" | awk '{print $1}')"
  cat > "$deb_root/DEBIAN/control" <<CONTROL
Package: fasttab
Version: $VERSION
Section: utils
Priority: optional
Architecture: $DEB_ARCH
Installed-Size: $installed_size
Maintainer: newyorkthink
Homepage: https://github.com/newyorkthink/fasttab
Depends: libasound2, libgl1, libx11-6, libx11-xcb1, libxcb1, libxcb-composite0, libxcb-damage0, libxcb-image0, libxcb-keysyms1, libxcursor1, libxi6, libxinerama1, libxrandr2
Description: Fast GPU-accelerated X11 window switcher
 FastTab is a low-latency Alt+Tab and Win+Tab window switcher for X11,
 implemented in Zig with Raylib and OpenGL.
CONTROL

  dpkg-deb --build --root-owner-group "$deb_root" "$OUT_DIR/$deb_name"
  (
    cd "$OUT_DIR"
    sha256sum "$deb_name" > "$deb_name.sha256"
  )
}

build_rpm() {
  mkdir -p "$RPM_TOP"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
  local spec="$RPM_TOP/SPECS/fasttab.spec"

  cat > "$spec" <<SPEC
Name:           fasttab
Version:        $VERSION
Release:        1%{?dist}
Summary:        Fast GPU-accelerated X11 window switcher
License:        GPL-3.0-only
URL:            https://github.com/newyorkthink/fasttab

%description
FastTab is a low-latency Alt+Tab and Win+Tab window switcher for X11,
implemented in Zig with Raylib and OpenGL.

%prep

%build

%install
rm -rf %{buildroot}
mkdir -p %{buildroot}
cp -a "$PACKAGE_ROOT"/. %{buildroot}/

%files
/usr/bin/fasttab
/usr/share/applications/fasttab.desktop
/usr/share/icons/hicolor/16x16/apps/fasttab.png
/usr/share/icons/hicolor/32x32/apps/fasttab.png
/usr/share/icons/hicolor/64x64/apps/fasttab.png
/usr/share/icons/hicolor/128x128/apps/fasttab.png
/usr/share/icons/hicolor/256x256/apps/fasttab.png
/usr/share/icons/hicolor/scalable/apps/fasttab.svg
/usr/share/pixmaps/fasttab.png
/usr/share/doc/fasttab/README.md
/usr/share/doc/fasttab/README.zh-CN.md
/usr/share/doc/fasttab/LICENSE.md

%changelog
* Sat Jul 11 2026 newyorkthink - $VERSION-1
- FastTab 2.0.7 intermittent transparent-preview fix
SPEC

  rpmbuild --define "_topdir $RPM_TOP" --target "$RPM_ARCH" -bb "$spec"
  local rpm_file
  rpm_file="$(find "$RPM_TOP/RPMS" -type f -name '*.rpm' -print -quit)"
  test -n "$rpm_file"
  cp "$rpm_file" "$OUT_DIR/"
  local rpm_name
  rpm_name="$(basename "$rpm_file")"
  (
    cd "$OUT_DIR"
    sha256sum "$rpm_name" > "$rpm_name.sha256"
  )
}

if (( BUILD_APPIMAGE )); then
  build_appimage
fi

if (( BUILD_NATIVE_PACKAGES )); then
  create_package_root
  if [[ "${FASTTAB_SKIP_DEB:-0}" != "1" ]]; then
    build_deb
  fi
  if [[ "${FASTTAB_SKIP_RPM:-0}" != "1" ]]; then
    build_rpm
  fi
fi

printf 'Created for %s:\n' "$APPIMAGE_ARCH"
find "$OUT_DIR" -maxdepth 1 -type f -printf '  %f (%s bytes)\n' | sort
