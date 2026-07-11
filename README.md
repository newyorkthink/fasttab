# FastTab

<p align="center">
  <img src="packaging/fasttab.svg" alt="FastTab logo" width="160">
</p>

<p align="center">
  <strong>English</strong> · <a href="README.zh-CN.md">简体中文</a>
</p>

FastTab is a fast GPU-accelerated Alt+Tab and Win+Tab window switcher for X11, written in Zig with Raylib and OpenGL.

## FastTab 2.0.0

FastTab 2.0.0 is the first formal multi-architecture release. It includes:

- Reliable global `Alt+Tab` switching and current-workspace `Win+Tab` switching.
- Correct `Win+Shift+Tab` handling for both ordinary `Tab` and layout-specific `ISO_Left_Tab` keycodes.
- CLI help and version output on standard output; errors remain on standard error.
- Native x86_64 and ARM64 builds.
- AppImage, DEB, and RPM packages for both architectures.
- Complete desktop icon installation at 16, 32, 64, 128, and 256 pixels, plus scalable SVG and pixmaps compatibility paths.

## Shortcuts

- `Alt+Tab`: display all tracked windows.
- `Win+Tab`: display windows on the current workspace, including a workspace containing one window.
- `Shift+Tab` or `Win+Shift+Tab`: navigate backwards.
- Arrow keys or `h`, `j`, `k`, `l`: navigate the grid.
- Mouse click: activate a window.
- `Enter`: confirm.
- `Esc`: cancel.
- Release `Alt` or `Super`: confirm the selected window.

Disable desktop-environment shortcuts that already use `Alt+Tab` or `Super+Tab` before starting FastTab.

## Features

- Persistent lightweight daemon with immediate switcher display.
- Live GPU-backed X11 window thumbnails.
- Window titles, application icons, workspace names, and workspace badges.
- MRU-aware selection and keyboard-first navigation.
- Current-workspace filtering for `Win+Tab`.
- Multi-monitor positioning and layouts that scale to smaller virtual displays.
- Single-instance protection.

## Requirements

- Linux with an X11 session.
- Hardware-accelerated OpenGL.
- x86_64 or ARM64/AArch64 CPU.

Wayland-native sessions are not supported.

## Downloads

Each release provides the following files:

| Architecture | AppImage | DEB | RPM |
|---|---|---|---|
| x86_64 / AMD64 | `FastTab-2.0.0-x86_64.AppImage` | `fasttab_2.0.0_amd64.deb` | `fasttab-2.0.0-1.x86_64.rpm` |
| ARM64 / AArch64 | `FastTab-2.0.0-aarch64.AppImage` | `fasttab_2.0.0_arm64.deb` | `fasttab-2.0.0-1.aarch64.rpm` |

SHA-256 checksum files and AppImage zsync metadata are published alongside the packages.

### AppImage

```bash
chmod +x FastTab-2.0.0-x86_64.AppImage
./FastTab-2.0.0-x86_64.AppImage
```

Use the `aarch64` file on ARM64 systems.

### Debian / Ubuntu

```bash
sudo apt install ./fasttab_2.0.0_amd64.deb
```

Use `fasttab_2.0.0_arm64.deb` on ARM64 systems.

### Fedora / RHEL-compatible distributions

```bash
sudo dnf install ./fasttab-2.0.0-1.x86_64.rpm
```

Use the `aarch64` RPM on ARM64 systems.

## Start FastTab

```bash
fasttab daemon
```

For i3, add this to the i3 configuration:

```text
exec --no-startup-id fasttab daemon
```

FastTab uses a per-user single-instance lock. Starting it again reports an error without terminating the running daemon.

## Command-line interface

```text
fasttab                  Start the daemon (default)
fasttab daemon           Start the daemon explicitly
fasttab --daemon         Start the daemon explicitly
fasttab help             Show help
fasttab -h, --help       Show help
fasttab version          Show the installed version
fasttab -v, -V, --version
                         Show the installed version
```

Unknown arguments return exit status `2` and print an error to standard error.

## Build from source

Install Zig 0.14.0 or later, a C toolchain, `make`, `curl`, `tar`, and the X11/OpenGL development libraries listed in the CI workflow.

```bash
git clone https://github.com/newyorkthink/fasttab.git
cd fasttab
./setup.sh
zig build test
zig build -Doptimize=ReleaseSafe -Dcpu=baseline
```

The binary is written to `zig-out/bin/fasttab`.

To create all packages on a supported native architecture:

```bash
bash ./build_packages.sh
```

To create only the AppImage:

```bash
./build_appimage.sh
```

## Installed desktop files

DEB and RPM packages install:

```text
/usr/share/applications/fasttab.desktop
/usr/share/icons/hicolor/16x16/apps/fasttab.png
/usr/share/icons/hicolor/32x32/apps/fasttab.png
/usr/share/icons/hicolor/64x64/apps/fasttab.png
/usr/share/icons/hicolor/128x128/apps/fasttab.png
/usr/share/icons/hicolor/256x256/apps/fasttab.png
/usr/share/icons/hicolor/scalable/apps/fasttab.svg
/usr/share/pixmaps/fasttab.png
```

## Technical design

FastTab runs as a background daemon, monitors X11 windows, and keeps GLX-backed thumbnails ready. The switcher UI is rendered through Raylib/OpenGL. This avoids generating screenshots only after the shortcut is pressed and keeps interaction latency low.
