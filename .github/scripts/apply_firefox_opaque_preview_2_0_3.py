from pathlib import Path
import re


def replace_once(path: str, old: str, new: str) -> None:
    p = Path(path)
    text = p.read_text(encoding="utf-8")
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected one match, found {count}: {old[:100]!r}")
    p.write_text(text.replace(old, new, 1), encoding="utf-8")


def regex_replace_once(path: str, pattern: str, replacement: str) -> None:
    p = Path(path)
    text = p.read_text(encoding="utf-8")
    updated, count = re.subn(pattern, replacement, text, count=1, flags=re.S)
    if count != 1:
        raise SystemExit(f"{path}: expected one regex match, found {count}: {pattern[:100]!r}")
    p.write_text(updated, encoding="utf-8")


# Firefox can expose an ARGB X11 pixmap whose alpha channel is zero even though
# the RGB channels contain a valid opaque window image. Prefer an RGB GLX
# binding so the server supplies an opaque alpha value. Keep RGBA as fallback
# for visuals that do not advertise RGB texture binding.
regex_replace_once(
    "src/x11.zig",
    r"fn findFBConfigForVisual\(.*?\n\}\n\nfn initDamage",
    '''fn findFBConfigForVisual(conn: *Connection, display: *xlib.Display, screen: c_int, visual_id: u32) ?xlib.GLXFBConfig {
    if (conn.fb_config_cache.get(visual_id)) |cached| {
        return cached;
    }

    var num_configs: c_int = 0;
    const configs = xlib.glXGetFBConfigs(display, screen, &num_configs) orelse return null;
    defer _ = xlib.XFree(@ptrCast(configs));

    var rgba_fallback: ?xlib.GLXFBConfig = null;

    for (0..@intCast(num_configs)) |i| {
        const cfg = configs[i];

        // Check visual ID matches
        var vis_id: c_int = 0;
        if (xlib.glXGetFBConfigAttrib(display, cfg, xlib.GLX_VISUAL_ID, &vis_id) != 0) continue;
        if (vis_id != @as(c_int, @intCast(visual_id))) continue;

        // Check it supports pixmap drawable type
        var drawable_type: c_int = 0;
        if (xlib.glXGetFBConfigAttrib(display, cfg, xlib.GLX_DRAWABLE_TYPE, &drawable_type) != 0) continue;
        if (drawable_type & xlib.GLX_PIXMAP_BIT == 0) continue;

        // Check 2D texture target support
        var bind_targets: c_int = 0;
        _ = xlib.glXGetFBConfigAttrib(display, cfg, xlib.GLX_BIND_TO_TEXTURE_TARGETS_EXT, &bind_targets);
        if (bind_targets & xlib.GLX_TEXTURE_2D_BIT_EXT == 0) continue;

        var bind_rgb: c_int = 0;
        var bind_rgba: c_int = 0;
        _ = xlib.glXGetFBConfigAttrib(display, cfg, xlib.GLX_BIND_TO_TEXTURE_RGB_EXT, &bind_rgb);
        _ = xlib.glXGetFBConfigAttrib(display, cfg, xlib.GLX_BIND_TO_TEXTURE_RGBA_EXT, &bind_rgba);

        // Top-level window previews are rendered as opaque. Prefer RGB so
        // Firefox's undefined/zero ARGB alpha cannot make the preview invisible.
        if (bind_rgb != 0) {
            conn.fb_config_cache.put(visual_id, cfg) catch {};
            return cfg;
        }
        if (rgba_fallback == null and bind_rgba != 0) {
            rgba_fallback = cfg;
        }
    }

    if (rgba_fallback) |cfg| {
        conn.fb_config_cache.put(visual_id, cfg) catch {};
        return cfg;
    }
    return null;
}

fn initDamage''',
)

replace_once(
    "src/x11.zig",
    '''    const texture_format = texture_format_hint orelse blk: {
        var bind_rgba: c_int = 0;
        _ = xlib.glXGetFBConfigAttrib(display, fb_config, xlib.GLX_BIND_TO_TEXTURE_RGBA_EXT, &bind_rgba);
        break :blk if (bind_rgba != 0) xlib.GLX_TEXTURE_FORMAT_RGBA_EXT else xlib.GLX_TEXTURE_FORMAT_RGB_EXT;
    };''',
    '''    const texture_format = texture_format_hint orelse blk: {
        var bind_rgb: c_int = 0;
        var bind_rgba: c_int = 0;
        _ = xlib.glXGetFBConfigAttrib(display, fb_config, xlib.GLX_BIND_TO_TEXTURE_RGB_EXT, &bind_rgb);
        _ = xlib.glXGetFBConfigAttrib(display, fb_config, xlib.GLX_BIND_TO_TEXTURE_RGBA_EXT, &bind_rgba);
        // Window previews are opaque; RGB avoids undefined alpha from ARGB clients such as Firefox.
        break :blk if (bind_rgb != 0) xlib.GLX_TEXTURE_FORMAT_RGB_EXT else xlib.GLX_TEXTURE_FORMAT_RGBA_EXT;
    };''',
)

# Force the rendered preview alpha to opaque as a second line of defence for
# visuals that can only be bound as RGBA. RGB is preserved and only alpha is
# replaced, so normal window colours remain unchanged.
replace_once(
    "src/shaders/downsample.fs",
    "    finalColor = (color / totalSamples) * fragColor;",
    '''    vec4 averaged = color / totalSamples;
    finalColor = vec4(averaged.rgb * fragColor.rgb, fragColor.a);''',
)

# Release metadata.
Path("VERSION").write_text("2.0.3\n", encoding="utf-8")
replace_once("src/main.zig", 'const FASTTAB_VERSION = "2.0.2";', 'const FASTTAB_VERSION = "2.0.3";')
replace_once("packaging/fasttab.desktop", "X-AppImage-Version=2.0.2", "X-AppImage-Version=2.0.3")
replace_once(
    "build_packages.sh",
    "- FastTab 2.0.2 cross-workspace preview persistence fix",
    "- FastTab 2.0.3 Firefox opaque preview compatibility fix",
)

# Documentation and versioned package names.
readme = Path("README.md")
text = readme.read_text(encoding="utf-8").replace("2.0.2", "2.0.3")
text = text.replace(
    "FastTab 2.0.3 is a cross-workspace preview persistence release. It includes:",
    "FastTab 2.0.3 fixes transparent Firefox previews while retaining the cross-workspace fixes from 2.0.2. It includes:",
    1,
)
text = text.replace(
    "- Capture the active window once before i3 changes workspace, preserving Firefox, Code Desktop, Antigravity, and other previews across repeated switches.",
    "- Prefer opaque RGB GLX bindings and force preview alpha to opaque, fixing Firefox windows that previously showed the desktop through an empty card.\n- Capture the active window once before i3 changes workspace, preserving Code Desktop, Antigravity, Vivaldi, and other previews across repeated switches.",
    1,
)
readme.write_text(text, encoding="utf-8")

readme_zh = Path("README.zh-CN.md")
text = readme_zh.read_text(encoding="utf-8").replace("2.0.2", "2.0.3")
text = text.replace(
    "FastTab 2.0.3 是跨工作区预览修复版本，主要包括：",
    "FastTab 2.0.3 修复 Firefox 透明空白预览，并保留 2.0.2 的跨工作区修复，主要包括：",
    1,
)
text = text.replace(
    "- 在 i3 切换工作区前同步保存当前活动窗口的一张预览，修复 Firefox、Code Desktop、Antigravity 等窗口切换两次后退化为应用图标的问题。",
    "- 优先使用不带透明通道的 RGB GLX 绑定，并强制缩略图保持不透明，修复 Firefox 卡片只透出桌面、没有窗口画面的问题。\n- 在 i3 切换工作区前同步保存当前活动窗口的一张预览，继续修复 Code Desktop、Antigravity、Vivaldi 等窗口反复切换后的预览丢失。",
    1,
)
readme_zh.write_text(text, encoding="utf-8")

# CI validation and release notes.
ci_path = Path(".github/workflows/ci.yml")
ci = ci_path.read_text(encoding="utf-8").replace("2.0.2", "2.0.3")
ci = ci.replace(
    "          grep -Fq 'fn cacheSnapshotForWindow' src/app.zig\n",
    "          grep -Fq 'fn cacheSnapshotForWindow' src/app.zig\n"
    "          grep -Fq 'Prefer RGB so' src/x11.zig\n"
    "          grep -Fq 'vec4(averaged.rgb * fragColor.rgb, fragColor.a)' src/shaders/downsample.fs\n",
    1,
)
old_notes = '''          FastTab 2.0.3 fixes cross-workspace preview loss under i3.

          Highlights:

          - Captures the real active window once before i3 unmaps it during a workspace switch.
          - Preserves Firefox, Code Desktop, Antigravity, Vivaldi, and other previews across repeated Alt+Tab and Win+Tab sessions.
          - Saves the last valid texture before GLX invalidation and retries transient failures without deleting the cached preview.
          - Keeps exit latency low: only the origin window is captured synchronously; remaining snapshots stay incremental.
          - Retains x86_64 and ARM64/AArch64 AppImage, DEB, and RPM packages.
'''
new_notes = '''          FastTab 2.0.3 fixes transparent Firefox previews under X11.

          Highlights:

          - Prefers opaque RGB GLX pixmap bindings for top-level window previews.
          - Forces rendered thumbnail alpha to opaque when a visual only supports RGBA binding.
          - Fixes Firefox cards that previously showed the desktop through an empty preview while the window was active.
          - Retains the i3 cross-workspace preview persistence and low-latency snapshot work from 2.0.2.
          - Retains x86_64 and ARM64/AArch64 AppImage, DEB, and RPM packages.
'''
if old_notes not in ci:
    raise SystemExit("ci.yml: expected 2.0.3 release notes block not found")
ci = ci.replace(old_notes, new_notes, 1)
ci_path.write_text(ci, encoding="utf-8")
