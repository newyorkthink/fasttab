#!/usr/bin/env python3
from __future__ import annotations

import sys
from pathlib import Path


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: fix_generated_gpu_source.py GENERATED_SOURCE_DIR")

    path = Path(sys.argv[1]) / "x11.zig"
    text = path.read_text(encoding="utf-8")
    old = """            rgba[output + 0] = expandRootChannel(pixel, conn.screen.*.red_mask);
            rgba[output + 1] = expandRootChannel(pixel, conn.screen.*.green_mask);
            rgba[output + 2] = expandRootChannel(pixel, conn.screen.*.blue_mask);
"""
    new = """            // X11 TrueColor root windows on supported modern desktops use
            // 0x00RRGGBB packed pixels. readRootPixel already normalizes byte order.
            rgba[output + 0] = @intCast((pixel >> 16) & 0xff);
            rgba[output + 1] = @intCast((pixel >> 8) & 0xff);
            rgba[output + 2] = @intCast(pixel & 0xff);
"""
    if text.count(old) != 1:
        raise SystemExit(f"expected one root mask block, found {text.count(old)}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")


if __name__ == "__main__":
    main()
