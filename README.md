# ⚡️ FastTab

<p align="center">
  <img src="packaging/fasttab.svg" alt="FastTab logo" width="160">
</p>

A lightning fast Alt+Tab switcher for X11 written in Zig using Raylib.

## Why this exists

FastTab exists because [`felixfung/skippy-xd`](https://github.com/felixfung/skippy-xd) is no longer a project I consider worth depending on.

`skippy-xd` had a good idea, but the implementation and maintenance have not kept up with what a real daily-use window switcher needs. Bugs remain unresolved, rough behavior is treated as normal, and basic interaction problems are left for users to tolerate. The result is a tool that feels neglected, fragile, and frustrating to use.

For something as fundamental as Alt+Tab, this is not acceptable. A window switcher should be fast, predictable, and reliable every time it is triggered. `skippy-xd` fails that standard. It can feel slow, awkward, visually outdated, and technically brittle. Instead of feeling like a polished desktop component, it feels like old X11 code that users are expected to work around.

FastTab is my answer to that mess.

This project is not a tiny patch, not a cosmetic fork, and not an attempt to politely preserve broken design decisions. FastTab fixes the bugs I actually hit, removes bad assumptions from the old approach, and rebuilds the switcher around a new Zig + Raylib + OpenGL architecture.

The goal is simple: a fast, clean, predictable X11 window switcher that works properly in real daily use instead of making users fight the tool.

# Skippy-XD is absolute garbage.
<img width="1920" height="761" alt="图片" src="https://github.com/user-attachments/assets/62a60fdb-0363-4894-a9e4-3e02e15adaf1" />



https://github.com/user-attachments/assets/6327cd4b-4750-40c8-ab30-f8d80463887d


## How It Works

- Press `Alt+Tab` to switch between all windows
- Press `Win+Tab` to display windows on the current workspace, including a workspace with exactly one window
- Press `Tab` to move to the next window
    - Hold `Shift` while pressing `Tab` to navigate backwards
    - Or quick tap the `Shift` key to move backwards
    - Or navigate using the arrow keys!
    - Or click on a window with the mouse!
    - And yes, keyboard takes precedence over the mouse, unlike _some other switcher_ 🤫
- Release `Alt` or `Win/Super` to confirm the switch


## Features

 - Instant window switching, no more waiting for the switcher to appear
 - UI with window thumbnails, titles, and icons
 - Smooth OpenGL rendering of the switcher UI
 - Lightweight daemon with low CPU and memory usage


## Motivation

I love my KDE Plasma desktop environment, but I find the default "Thumbnail Grid" switcher to be a bit too slow for my taste: sometimes it would take up to a second to appear, which is too long when you want to quickly switch between windows.

I believe this is because the default switcher has a major performance compromise: it generates window thumbnails on the fly when the switcher is invoked.

This _does_ make sense normally because it means that you're not wasting resources generating thumbnails for windows you might never switch to. And most likely, lots of users don't use Alt+Tab that often.

I am, however, in the opposite camp: I Alt+Tab all the time, my computer can handle the extra cpu (very little) and memory (some) no problem, and even a slight delay irritates me.

So I decided to try out writing my own Alt+Tab switcher.

FastTab improves performance in several ways:
 - It runs as a daemon in the background, constantly monitoring windows and maintaining live thumbnails.
 - It uses OpenGL via Raylib for fast rendering of the switcher UI
 - Window thumbnails are rendered entirely on the GPU using GLX texture binding (zero-copy, no CPU overhead).
 - Live thumbnail updates reflect window content changes in real-time without capturing screenshots.
 - It's written in Zig!

## Prerequisites

 - An X11-based desktop environment (e.g. KDE Plasma, Xfce, etc)
 - Hardware-accelerated OpenGL support
 - Rebind the default `Alt+Tab` shortcuts to something else (e.g. `Ctrl+Meta+Tab`, `Ctrl+Meta+Shift+Tab`), to avoid conflicts.
 - To use **Win+Tab** (current-workspace switcher): disable any desktop-environment shortcut that uses `Super+Tab`.

## Build instructions

1. Install Zig 0.14.0 or later.
2. Install `curl`, `tar`, and the required development packages:

    - libasound2-dev
    - libgl1-mesa-dev
    - libglu1-mesa-dev
    - libwayland-dev
    - libx11-dev
    - libx11-xcb-dev
    - libxcb-composite0-dev
    - libxcb-damage0-dev
    - libxcb-image0-dev
    - libxcb-keysyms1-dev
    - libxcb-shm0-dev
    - libxcb-util0-dev
    - libxcb1-dev
    - libxcursor-dev
    - libxi-dev
    - libxinerama-dev
    - libxkbcommon-dev
    - libxrandr-dev
    - libglfw3-dev

3. Clone this repository.
4. Run `./setup.sh` to download the pinned Raylib release and STB headers.
5. Run `zig build test`.
6. Build with `zig build -Doptimize=ReleaseSafe -Dcpu=baseline`.
7. The binary will be available at `./zig-out/bin/fasttab`.

To build the portable x86_64 AppImage inside the AnyLinux/quick-sharun environment, run `./build_appimage.sh`.

## Installation instructions

### AppImage

1. Download `FastTab-1.0.5-x86_64.AppImage` and its checksum from the [releases page](https://github.com/newyorkthink/fasttab/releases/latest).
2. Verify it with `sha256sum -c FastTab-1.0.5-x86_64.AppImage.sha256`.
3. Run `chmod +x FastTab-1.0.5-x86_64.AppImage`.
4. Start it with `./FastTab-1.0.5-x86_64.AppImage &`.

The AppImage automatically replaces an older running FastTab daemon. Version 1.0.5 keeps the single-window `Win+Tab` behavior and embeds `REUSE_CHECK_DELAY=0` in uruntime, removing the several-second delay after pressing `Ctrl+C` during a foreground AppImage run.

### Standalone binary

1. Download `fasttab-x86_64` and its checksum from the releases page, or build the project locally.
2. Move it somewhere in your PATH, such as `/usr/local/bin/fasttab`.
3. Run `fasttab daemon --replace &` to replace any older daemon and start the new binary.
4. Try Alt+Tabbing around.


#### ⚠️ DISCLAIMERS
 - Consider this Very Beta. It works for me, but your mileage may vary.
 - Yes I did use AI to help me write a lot of this code. On one hand I would have preferred to write it all myself, but on the other hand I would not have been able to finish it in a reasonable amount of time. So here we are.
