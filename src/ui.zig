const std = @import("std");
const thumbnail = @import("thumbnail.zig");
const x11 = @import("x11.zig");
const layout_module = @import("layout.zig");

pub const rl = @cImport({
    @cInclude("raylib.h");
});

// Re-export constants from layout module
pub const THUMBNAIL_HEIGHT = layout_module.THUMBNAIL_HEIGHT;
pub const SPACING = layout_module.SPACING;
pub const PADDING = layout_module.PADDING;
pub const MAX_GRID_WIDTH = layout_module.MAX_GRID_WIDTH;
pub const MAX_GRID_HEIGHT = layout_module.MAX_GRID_HEIGHT;
pub const TITLE_FONT_SIZE = layout_module.TITLE_FONT_SIZE;
pub const TITLE_SPACING = layout_module.TITLE_SPACING;

// UI-only constants
pub const SELECTION_BORDER: u32 = 3;
pub const BACKGROUND_COLOR = rl.Color{ .r = 0x22, .g = 0x22, .b = 0x22, .a = 217 };
pub const HIGHLIGHT_COLOR = rl.Color{ .r = 0x2d, .g = 0x8e, .b = 0xc9, .a = 128 };
pub const HIGHLIGHT_COLOR_LINES = rl.Color{ .r = 0x3d, .g = 0xae, .b = 0xe9, .a = 255 };
pub const HIGHLIGHT_COLOR_LESS = rl.Color{ .r = 0x2d, .g = 0x8e, .b = 0xc9, .a = 64 };
pub const HIGHLIGHT_COLOR_LESS_LINES = rl.Color{ .r = 0x3d, .g = 0xae, .b = 0xe9, .a = 128 };
pub const TITLE_COLOR = rl.Color{ .r = 255, .g = 255, .b = 255, .a = 255 };
pub const WORKSPACE_BAR_HEIGHT: u32 = 32;
pub const WORKSPACE_BAR_SPACING: u32 = 10;
pub const WORKSPACE_FONT_SIZE: i32 = 17;
pub const WORKSPACE_ITEM_PADDING_X: u32 = 10;
pub const WORKSPACE_ITEM_SPACING: u32 = 8;
pub const WORKSPACE_CURRENT_BG = rl.Color{ .r = 0x2d, .g = 0x8e, .b = 0xc9, .a = 160 };
pub const WORKSPACE_CURRENT_BORDER = rl.Color{ .r = 0x3d, .g = 0xae, .b = 0xe9, .a = 255 };
pub const WORKSPACE_TEXT_COLOR = rl.Color{ .r = 255, .g = 255, .b = 255, .a = 235 };
pub const WINDOW_WORKSPACE_BADGE_FONT_SIZE: i32 = 14;
pub const WINDOW_WORKSPACE_BADGE_PADDING_X: u32 = 7;
pub const WINDOW_WORKSPACE_BADGE_PADDING_Y: u32 = 3;
pub const WINDOW_WORKSPACE_BADGE_MARGIN: u32 = 7;
pub const WINDOW_WORKSPACE_BADGE_MIN_SIZE: u32 = 24;
pub const WINDOW_WORKSPACE_BADGE_BG = rl.Color{ .r = 0x12, .g = 0x12, .b = 0x12, .a = 190 };
pub const WINDOW_WORKSPACE_BADGE_BORDER = rl.Color{ .r = 0x3d, .g = 0xae, .b = 0xe9, .a = 210 };
pub const WINDOW_WORKSPACE_BADGE_TEXT = rl.Color{ .r = 255, .g = 255, .b = 255, .a = 245 };
pub const ROUNDNESS: f32 = 0.08;

// Icon overlay constants
pub const ICON_HEIGHT_RATIO: f32 = 0.25;
pub const ICON_BOTTOM_OVERHANG: f32 = 0.05;

// Downsample shader for high-quality thumbnail scaling (embedded at compile time)
pub const DownsampleShader = struct {
    shader: rl.Shader,
    source_size_loc: c_int,
    dest_size_loc: c_int,

    // Embed shader source at compile time
    const vs_source = @embedFile("shaders/downsample.vs");
    const fs_source = @embedFile("shaders/downsample.fs");

    pub fn load() ?DownsampleShader {
        const shader = rl.LoadShaderFromMemory(vs_source, fs_source);
        if (shader.id == 0) {
            std.log.warn("Failed to load downsample shader, falling back to bilinear", .{});
            return null;
        }

        return DownsampleShader{
            .shader = shader,
            .source_size_loc = rl.GetShaderLocation(shader, "sourceSize"),
            .dest_size_loc = rl.GetShaderLocation(shader, "destSize"),
        };
    }

    pub fn unload(self: *DownsampleShader) void {
        rl.UnloadShader(self.shader);
    }

    pub fn begin(self: *const DownsampleShader, source_w: f32, source_h: f32, dest_w: f32, dest_h: f32) void {
        const source_size = [2]f32{ source_w, source_h };
        const dest_size = [2]f32{ dest_w, dest_h };
        rl.SetShaderValue(self.shader, self.source_size_loc, &source_size, rl.SHADER_UNIFORM_VEC2);
        rl.SetShaderValue(self.shader, self.dest_size_loc, &dest_size, rl.SHADER_UNIFORM_VEC2);
        rl.BeginShaderMode(self.shader);
    }

    pub fn end(_: *const DownsampleShader) void {
        rl.EndShaderMode();
    }
};

// Item holding window data for rendering
pub const DisplayWindow = struct {
    id: x11.xcb.xcb_window_t,
    title: []const u8, // owned
    thumbnail_texture: rl.Texture2D, // GPU handle
    icon_texture: ?rl.Texture2D, // non-owning copy from icon_texture_cache
    icon_id: []const u8, // owned (WM_CLASS)
    title_version: u32,
    thumbnail_version: u32,
    source_width: u32, // original thumbnail width (for layout)
    source_height: u32, // original thumbnail height (for layout)
    display_width: u32,
    display_height: u32,
    thumbnail_ready: bool,
    cached_snapshot: ?rl.RenderTexture2D,
    workspace: ?u32 = null,
};

// Re-export GridLayout from layout module
pub const GridLayout = layout_module.GridLayout;

// Re-export pure layout functions
pub const calculateThumbnailSize = layout_module.calculateThumbnailSize;
pub const ThumbnailSize = layout_module.ThumbnailSize;
pub const MAX_THUMBNAIL_WIDTH = layout_module.MAX_THUMBNAIL_WIDTH;

pub fn calculateGridLayout(items: []DisplayWindow, target_height: u32) GridLayout {
    return calculateGridLayoutWithin(items, target_height, MAX_GRID_WIDTH, MAX_GRID_HEIGHT);
}

pub fn calculateGridLayoutWithin(items: []DisplayWindow, target_height: u32, max_grid_width: u32, max_grid_height: u32) GridLayout {
    if (items.len == 0) {
        return GridLayout{
            .columns = 0,
            .rows = 0,
            .item_height = target_height,
            .total_width = PADDING * 2,
            .total_height = PADDING * 2,
        };
    }

    for (items) |*item| {
        const size = calculateThumbnailSize(item.source_width, item.source_height, MAX_THUMBNAIL_WIDTH, target_height);
        item.display_width = size.width;
        item.display_height = size.height;
    }

    const item_full_height = target_height + TITLE_SPACING + @as(u32, @intCast(TITLE_FONT_SIZE));

    var best_columns: u32 = 1;
    var best_rows: u32 = @intCast(items.len);
    var found_fit = false;

    var cols: u32 = 1;
    while (cols <= items.len) : (cols += 1) {
        const rows_usize = (items.len + @as(usize, @intCast(cols)) - 1) / @as(usize, @intCast(cols));
        const rows: u32 = @intCast(rows_usize);

        var max_row_width: u32 = 0;
        var row_start: u32 = 0;
        while (row_start < items.len) {
            const items_in_row = @min(cols, @as(u32, @intCast(items.len)) - row_start);
            const row_width = calculateRowWidth(items, row_start, items_in_row);
            if (row_width > max_row_width) max_row_width = row_width;
            row_start += cols;
        }

        const estimated_width = PADDING * 2 + max_row_width;
        const estimated_height = PADDING * 2 + rows * item_full_height + (rows - 1) * SPACING;

        if (estimated_width <= max_grid_width and estimated_height <= max_grid_height) {
            best_columns = cols;
            best_rows = rows;
            found_fit = true;
        } else if (estimated_width > max_grid_width and found_fit) {
            break;
        }
    }

    var max_row_width: u32 = 0;
    var row_start: u32 = 0;
    while (row_start < items.len) {
        const items_in_row = @min(best_columns, @as(u32, @intCast(items.len)) - row_start);
        const row_width = calculateRowWidth(items, row_start, items_in_row);
        if (row_width > max_row_width) {
            max_row_width = row_width;
        }
        row_start += best_columns;
    }
    const total_width = PADDING * 2 + max_row_width;
    const total_height = PADDING * 2 + best_rows * item_full_height + (best_rows - 1) * SPACING;

    return GridLayout{
        .columns = best_columns,
        .rows = best_rows,
        .item_height = target_height,
        .total_width = total_width,
        .total_height = total_height,
    };
}

pub fn calculateBestLayout(items: []DisplayWindow) GridLayout {
    return calculateBestLayoutWithin(items, MAX_GRID_WIDTH, MAX_GRID_HEIGHT);
}

pub fn calculateBestLayoutWithin(items: []DisplayWindow, max_grid_width: u32, max_grid_height: u32) GridLayout {
    var layout = calculateGridLayoutWithin(items, THUMBNAIL_HEIGHT, max_grid_width, max_grid_height);
    var current_height: u32 = THUMBNAIL_HEIGHT;
    while ((layout.total_width > max_grid_width or layout.total_height > max_grid_height) and current_height > 60) {
        current_height -= 10;
        layout = calculateGridLayoutWithin(items, current_height, max_grid_width, max_grid_height);
    }
    return layout;
}

pub fn calculateBestLayoutForMonitor(items: []DisplayWindow, monitor_width: i32, monitor_height: i32, workspace_names: []const []const u8) GridLayout {
    const monitor_w: u32 = if (monitor_width > 0) @intCast(monitor_width) else MAX_GRID_WIDTH;
    const monitor_h: u32 = if (monitor_height > 0) @intCast(monitor_height) else MAX_GRID_HEIGHT;

    const max_grid_width = if (monitor_w > 120) @min(MAX_GRID_WIDTH, monitor_w - 80) else monitor_w;
    const max_total_height = if (monitor_h > 120) @min(MAX_GRID_HEIGHT, monitor_h - 80) else monitor_h;
    const top_offset = workspaceBarOffset(workspace_names);
    const max_grid_height = if (max_total_height > top_offset + PADDING * 2)
        max_total_height - top_offset
    else
        max_total_height;

    var layout = calculateBestLayoutWithin(items, max_grid_width, max_grid_height);
    addWorkspaceBarToLayout(&layout, workspace_names);
    return layout;
}

pub fn calculateRowWidth(items: []DisplayWindow, start_idx: u32, count: u32) u32 {
    var width: u32 = 0;
    const end = @min(start_idx + count, @as(u32, @intCast(items.len)));
    var i = start_idx;
    while (i < end) : (i += 1) {
        width += items[i].display_width;
        if (i < end - 1) {
            width += SPACING;
        }
    }
    return width;
}

pub fn getItemAtPosition(items: []DisplayWindow, layout: GridLayout, mouse_pos: rl.Vector2, top_offset: u32) ?usize {
    if (items.len == 0) return null;

    const item_full_height = layout.item_height + TITLE_SPACING + @as(u32, @intCast(TITLE_FONT_SIZE));

    var item_idx: usize = 0;
    var row: u32 = 0;
    while (row < layout.rows and item_idx < items.len) : (row += 1) {
        const items_in_row = @min(layout.columns, @as(u32, @intCast(items.len)) - @as(u32, @intCast(item_idx)));

        const row_width = calculateRowWidth(items, @intCast(item_idx), items_in_row);
        var x: f32 = @floatFromInt(PADDING + (layout.total_width - 2 * PADDING - row_width) / 2);
        const y: f32 = @floatFromInt(PADDING + top_offset + row * (item_full_height + SPACING));

        var col: u32 = 0;
        while (col < items_in_row) : (col += 1) {
            const item = &items[item_idx];

            const hit_rect = rl.Rectangle{
                .x = x - @as(f32, @floatFromInt(SELECTION_BORDER)),
                .y = y - @as(f32, @floatFromInt(SELECTION_BORDER)),
                .width = @as(f32, @floatFromInt(item.display_width + 2 * SELECTION_BORDER)),
                .height = @as(f32, @floatFromInt(item_full_height + 2 * SELECTION_BORDER)),
            };

            if (rl.CheckCollisionPointRec(mouse_pos, hit_rect)) {
                return item_idx;
            }

            x += @as(f32, @floatFromInt(item.display_width + SPACING));
            item_idx += 1;
        }
    }
    return null;
}

pub fn loadTextureFromThumbnail(thumb: *const thumbnail.Thumbnail) rl.Texture2D {
    const image = rl.Image{
        .data = thumb.data.ptr,
        .width = @intCast(thumb.width),
        .height = @intCast(thumb.height),
        .format = rl.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8,
        .mipmaps = 1,
    };
    const texture = rl.LoadTextureFromImage(image);
    rl.SetTextureFilter(texture, rl.TEXTURE_FILTER_BILINEAR);
    return texture;
}

fn tryLoadFont(path: [*c]const u8, size: i32, codepoints: [*c]c_int, count: usize) ?rl.Font {
    const font = rl.LoadFontEx(path, size, codepoints, @intCast(count));

    // raylib may return its built-in bitmap font when a font file cannot be parsed
    // or when the requested atlas cannot be created. Reject that fallback; otherwise
    // English looks blocky and CJK glyphs render as '?'.
    if (font.texture.id == 0 or font.glyphCount < 1024) {
        if (font.texture.id != 0) rl.UnloadFont(font);
        return null;
    }

    rl.SetTextureFilter(font.texture, rl.TEXTURE_FILTER_BILINEAR);
    return font;
}

fn utf8SequenceLength(first: u8) usize {
    if (first < 0x80) return 1;
    if ((first & 0xE0) == 0xC0) return 2;
    if ((first & 0xF0) == 0xE0) return 3;
    if ((first & 0xF8) == 0xF0) return 4;
    return 1;
}

fn utf8PrefixLen(text: []const u8, max_len: usize) usize {
    var i: usize = 0;
    while (i < text.len and i < max_len) {
        const seq_len = utf8SequenceLength(text[i]);
        if (i + seq_len > text.len or i + seq_len > max_len) break;
        i += seq_len;
    }
    return i;
}


fn isFontFile(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".ttf") or
        std.mem.endsWith(u8, name, ".otf") or
        std.mem.endsWith(u8, name, ".ttc");
}

fn fontNameMatches(name: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (std.ascii.indexOfIgnoreCase(name, needle) != null) return true;
    }
    return false;
}

fn tryLoadFontRecursive(
    dir_path: []const u8,
    depth: u8,
    size: i32,
    codepoints: [*c]c_int,
    count: usize,
    needles: []const []const u8,
) ?rl.Font {
    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return null;
    defer dir.close();

    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
        const full_path = std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;

        if (entry.kind == .directory and depth > 0) {
            if (tryLoadFontRecursive(full_path, depth - 1, size, codepoints, count, needles)) |font| return font;
        } else if (entry.kind == .file and isFontFile(entry.name) and fontNameMatches(entry.name, needles)) {
            if (tryLoadFont(full_path.ptr, size, codepoints, count)) |font| return font;
        }
    }

    return null;
}

pub fn loadSystemFont(size: i32) rl.Font {
    // Keep the atlas small enough to load reliably, while still supporting Chinese titles.
    var codepoints: [32768]c_int = undefined;
    var count: usize = 0;

    const ranges = [_][2]c_int{
        .{ 0x0020, 0x007E }, // Basic Latin
        .{ 0x00A0, 0x00FF }, // Latin-1 Supplement
        .{ 0x0100, 0x017F }, // Latin Extended-A
        .{ 0x2000, 0x206F }, // General Punctuation
        .{ 0x3000, 0x303F }, // CJK Symbols and Punctuation
        .{ 0x4E00, 0x9FFF }, // CJK Unified Ideographs
        .{ 0xFF00, 0xFFEF }, // Fullwidth Forms
    };

    for (ranges) |range| {
        var c = range[0];
        while (c <= range[1]) : (c += 1) {
            if (count < codepoints.len) {
                codepoints[count] = c;
                count += 1;
            }
        }
    }

    const cjk_preferred_needles = [_][]const u8{
        "NotoSansCJK",
        "NotoSansSC",
        "SourceHanSans",
        "SourceHanSansSC",
        "SourceHanSansCN",
        "AdobeHeiti",
        "AdobeSong",
        "wqy-microhei",
        "wqy-zenhei",
    };

    // User-local fonts first, without hard-coding /home/user.
    // Prefer real OTF/TTF CJK fonts when present; reject raylib's built-in fallback.
    if (std.process.getEnvVarOwned(std.heap.page_allocator, "HOME")) |home| {
        defer std.heap.page_allocator.free(home);

        const local_paths = [_][]const u8{
            ".local/share/fonts/noto-cjk/NotoSansCJK-Regular.otf",
            ".local/share/fonts/noto-cjk/NotoSansSC-Regular.otf",
            ".local/share/fonts/adobe-font-folio-11.0/SourceHanSansSC-Regular.otf",
            ".local/share/fonts/adobe-font-folio-11.0/SourceHanSansCN-Regular.otf",
            ".local/share/fonts/adobe-font-folio-11.0/AdobeHeitiStd-Regular.otf",
            ".local/share/fonts/adobe-font-folio-11.0/AdobeSongStd-Light.otf",
            ".local/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc",
            ".local/share/fonts/wenquanyi/wqy-microhei/wqy-microhei.ttc",
            ".local/share/fonts/wenquanyi/wqy-zenhei/wqy-zenhei.ttc",
        };
        for (local_paths) |rel| {
            var buf: [std.fs.max_path_bytes:0]u8 = undefined;
            if (std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ home, rel })) |path| {
                if (tryLoadFont(path.ptr, size, &codepoints[0], count)) |font| return font;
            } else |_| {}
        }

        var fonts_dir_buf: [std.fs.max_path_bytes:0]u8 = undefined;
        if (std.fmt.bufPrint(&fonts_dir_buf, "{s}/.local/share/fonts", .{home})) |fonts_dir| {
            if (tryLoadFontRecursive(fonts_dir, 4, size, &codepoints[0], count, &cjk_preferred_needles)) |font| return font;
        } else |_| {}
    } else |_| {}

    const font_paths = [_][*c]const u8{
        // Prefer CJK fonts that also have acceptable Latin glyphs.
        "/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc",
        "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
        "/usr/share/fonts/google-noto-cjk/NotoSansCJK-Regular.ttc",
        "/usr/share/fonts/noto-cjk/NotoSansSC-Regular.otf",
        "/usr/share/fonts/adobe-source-han-sans/SourceHanSansSC-Regular.otf",
        "/usr/share/fonts/source-han-sans/SourceHanSansSC-Regular.otf",

        // WenQuanYi fallback.
        "/usr/share/fonts/wenquanyi/wqy-microhei/wqy-microhei.ttc",
        "/usr/share/fonts/wenquanyi/wqy-zenhei/wqy-zenhei.ttc",

        // Last-resort Latin fonts.
        "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",
        "/usr/share/fonts/noto/NotoSans-Regular.ttf",
        "/usr/share/fonts/google-noto/NotoSans-Regular.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/TTF/DejaVuSans.ttf",
        "/usr/share/fonts/dejavu-sans-fonts/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
        "/usr/share/fonts/liberation-sans/LiberationSans-Regular.ttf",
    };

    for (font_paths) |path| {
        if (tryLoadFont(path, size, &codepoints[0], count)) |font| return font;
    }

    const system_dirs = [_][]const u8{
        "/usr/share/fonts",
        "/usr/local/share/fonts",
    };
    for (system_dirs) |dir| {
        if (tryLoadFontRecursive(dir, 5, size, &codepoints[0], count, &cjk_preferred_needles)) |font| return font;
    }

    return rl.GetFontDefault();
}

fn drawTextExWeight(font: rl.Font, text_ptr: [*c]const u8, x: f32, y: f32, font_size: f32, spacing: f32, color: rl.Color, bold: bool) void {
    const pos = rl.Vector2{ .x = @floor(x), .y = @floor(y) };
    rl.DrawTextEx(font, text_ptr, pos, font_size, spacing, color);
    if (bold) {
        rl.DrawTextEx(font, text_ptr, rl.Vector2{ .x = pos.x + 1.0, .y = pos.y }, font_size, spacing, color);
    }
}

fn drawTruncatedTextWithWeight(font: rl.Font, text: []const u8, x: f32, y: f32, font_size: f32, max_width: f32, color: rl.Color, bold: bool) void {
    const spacing: f32 = 1;
    var text_buf: [256]u8 = undefined;
    const ellipsis = "...";

    const len = utf8PrefixLen(text, text_buf.len - 1);
    @memcpy(text_buf[0..len], text[0..len]);
    text_buf[len] = 0;

    const text_ptr: [*c]const u8 = &text_buf;
    const text_size = rl.MeasureTextEx(font, text_ptr, font_size, spacing);

    if (text_size.x <= max_width) {
        const text_x = x + (max_width - text_size.x) / 2.0;
        drawTextExWeight(font, text_ptr, text_x, y, font_size, spacing, color, bold);
        return;
    }

    const ellipsis_size = rl.MeasureTextEx(font, ellipsis, font_size, spacing);
    const available_width = max_width - ellipsis_size.x;

    var fit_len: usize = 0;
    var i: usize = 0;
    while (i < len) {
        const seq_len = utf8SequenceLength(text_buf[i]);
        const next_i = i + seq_len;
        if (next_i > len) break;

        const saved_char = text_buf[next_i];
        text_buf[next_i] = 0;
        const partial_size = rl.MeasureTextEx(font, text_ptr, font_size, spacing);
        text_buf[next_i] = saved_char;
        if (partial_size.x > available_width) break;

        fit_len = next_i;
        i = next_i;
    }

    if (fit_len > 0) {
        @memcpy(text_buf[fit_len .. fit_len + 3], ellipsis);
        text_buf[fit_len + 3] = 0;
    } else {
        @memcpy(text_buf[0..3], ellipsis);
        text_buf[3] = 0;
    }

    const final_size = rl.MeasureTextEx(font, text_ptr, font_size, spacing);
    const text_x = x + (max_width - final_size.x) / 2.0;
    drawTextExWeight(font, text_ptr, text_x, y, font_size, spacing, color, bold);
}

fn drawTruncatedText(font: rl.Font, text: []const u8, x: f32, y: f32, font_size: f32, max_width: f32, color: rl.Color) void {
    drawTruncatedTextWithWeight(font, text, x, y, font_size, max_width, color, false);
}

fn drawTruncatedTextBold(font: rl.Font, text: []const u8, x: f32, y: f32, font_size: f32, max_width: f32, color: rl.Color) void {
    drawTruncatedTextWithWeight(font, text, x, y, font_size, max_width, color, true);
}



pub fn workspaceBarOffset(workspace_names: []const []const u8) u32 {
    return if (workspace_names.len == 0) 0 else WORKSPACE_BAR_HEIGHT + WORKSPACE_BAR_SPACING;
}

pub fn addWorkspaceBarToLayout(layout: *GridLayout, workspace_names: []const []const u8) void {
    layout.total_height += workspaceBarOffset(workspace_names);
}

fn measureUiText(font: rl.Font, text: []const u8, font_size: f32) rl.Vector2 {
    var text_buf: [128]u8 = undefined;
    const len = utf8PrefixLen(text, text_buf.len - 1);
    @memcpy(text_buf[0..len], text[0..len]);
    text_buf[len] = 0;
    const text_ptr: [*c]const u8 = &text_buf;
    return rl.MeasureTextEx(font, text_ptr, font_size, 1);
}

fn workspaceItemWidth(font: rl.Font, name: []const u8) u32 {
    const measured = measureUiText(font, name, @floatFromInt(WORKSPACE_FONT_SIZE));
    const text_w: u32 = if (measured.x < 1.0) 1 else @intFromFloat(@ceil(measured.x));
    return text_w + WORKSPACE_ITEM_PADDING_X * 2;
}

fn drawWorkspaceBar(font: rl.Font, workspace_names: []const []const u8, current_workspace: ?u32, total_width: u32) void {
    if (workspace_names.len == 0) return;

    var bar_width: u32 = 0;
    for (workspace_names, 0..) |name, i| {
        bar_width += workspaceItemWidth(font, name);
        if (i + 1 < workspace_names.len) bar_width += WORKSPACE_ITEM_SPACING;
    }

    const available_width = if (total_width > PADDING * 2) total_width - PADDING * 2 else total_width;
    const start_x: f32 = if (bar_width <= available_width)
        @floatFromInt((total_width - bar_width) / 2)
    else
        @floatFromInt(PADDING);

    var x = start_x;
    const y: f32 = @floatFromInt(PADDING);

    for (workspace_names, 0..) |name, i| {
        const item_w = workspaceItemWidth(font, name);
        const rect = rl.Rectangle{
            .x = x,
            .y = y,
            .width = @floatFromInt(item_w),
            .height = @floatFromInt(WORKSPACE_BAR_HEIGHT),
        };

        if (current_workspace != null and current_workspace.? == i) {
            rl.DrawRectangleRec(rect, WORKSPACE_CURRENT_BG);
            rl.DrawRectangleLinesEx(rect, 1, WORKSPACE_CURRENT_BORDER);
        }

        const text_y = y + @as(f32, @floatFromInt(WORKSPACE_BAR_HEIGHT - @as(u32, @intCast(WORKSPACE_FONT_SIZE)))) / 2.0;
        drawTruncatedTextBold(
            font,
            name,
            x + @as(f32, @floatFromInt(WORKSPACE_ITEM_PADDING_X)),
            text_y,
            @floatFromInt(WORKSPACE_FONT_SIZE),
            @floatFromInt(item_w - WORKSPACE_ITEM_PADDING_X * 2),
            WORKSPACE_TEXT_COLOR,
        );

        x += @as(f32, @floatFromInt(item_w + WORKSPACE_ITEM_SPACING));
    }
}


fn workspaceLabel(workspace_names: []const []const u8, workspace: ?u32) ?[]const u8 {
    const idx = workspace orelse return null;
    if (idx == 0xFFFFFFFF) return "*";

    const index: usize = @intCast(idx);
    if (index < workspace_names.len) return workspace_names[index];
    return null;
}

fn drawWindowWorkspaceBadge(font: rl.Font, workspace_names: []const []const u8, workspace: ?u32, x: f32, y: f32, width: u32) void {
    const label = workspaceLabel(workspace_names, workspace) orelse return;

    const font_size: f32 = @floatFromInt(WINDOW_WORKSPACE_BADGE_FONT_SIZE);
    const measured = measureUiText(font, label, font_size);
    const text_w: u32 = if (measured.x < 1.0) 1 else @intFromFloat(@ceil(measured.x));
    const text_h: u32 = @intCast(WINDOW_WORKSPACE_BADGE_FONT_SIZE);
    const content_w = text_w + WINDOW_WORKSPACE_BADGE_PADDING_X * 2;
    const content_h = text_h + WINDOW_WORKSPACE_BADGE_PADDING_Y * 2;
    const badge_size = @max(WINDOW_WORKSPACE_BADGE_MIN_SIZE, @max(content_w, content_h));

    if (width <= badge_size + WINDOW_WORKSPACE_BADGE_MARGIN * 2) return;

    const badge_x = x + @as(f32, @floatFromInt(width - badge_size - WINDOW_WORKSPACE_BADGE_MARGIN));
    const badge_y = y + @as(f32, @floatFromInt(WINDOW_WORKSPACE_BADGE_MARGIN));
    const rect = rl.Rectangle{
        .x = badge_x,
        .y = badge_y,
        .width = @floatFromInt(badge_size),
        .height = @floatFromInt(badge_size),
    };

    rl.DrawRectangleRec(rect, WINDOW_WORKSPACE_BADGE_BG);
    rl.DrawRectangleLinesEx(rect, 1, WINDOW_WORKSPACE_BADGE_BORDER);

    const text_x = badge_x + (@as(f32, @floatFromInt(badge_size)) - @as(f32, @floatFromInt(text_w))) / 2.0;
    const text_y = badge_y + (@as(f32, @floatFromInt(badge_size)) - font_size) / 2.0;
    drawTruncatedTextBold(
        font,
        label,
        text_x,
        text_y,
        font_size,
        @floatFromInt(text_w),
        WINDOW_WORKSPACE_BADGE_TEXT,
    );
}

pub fn renderSwitcher(
    items: []DisplayWindow,
    layout: GridLayout,
    selected_index: usize,
    mouseover_index: ?usize,
    font: rl.Font,
    downsample_shader: ?*const DownsampleShader,
    workspace_names: []const []const u8,
    current_workspace: ?u32,
) void {
    if (items.len == 0) return;

    const item_full_height = layout.item_height + TITLE_SPACING + @as(u32, @intCast(TITLE_FONT_SIZE));
    const top_offset = workspaceBarOffset(workspace_names);

    const bg_rect = rl.Rectangle{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(layout.total_width),
        .height = @floatFromInt(layout.total_height),
    };
    rl.DrawRectangleRounded(bg_rect, ROUNDNESS, 16, BACKGROUND_COLOR);
    drawWorkspaceBar(font, workspace_names, current_workspace, layout.total_width);

    var item_idx: usize = 0;
    var row: u32 = 0;
    while (row < layout.rows and item_idx < items.len) : (row += 1) {
        const items_in_row = @min(layout.columns, @as(u32, @intCast(items.len)) - @as(u32, @intCast(item_idx)));

        const row_width = calculateRowWidth(items, @intCast(item_idx), items_in_row);
        var x: f32 = @floatFromInt(PADDING + (layout.total_width - 2 * PADDING - row_width) / 2);
        const y: f32 = @floatFromInt(PADDING + top_offset + row * (item_full_height + SPACING));

        var col: u32 = 0;
        while (col < items_in_row) : (col += 1) {
            const item = &items[item_idx];
            const is_selected = item_idx == selected_index;

            if (is_selected) {
                const highlight_rect = rl.Rectangle{
                    .x = x - @as(f32, @floatFromInt(SELECTION_BORDER)),
                    .y = y - @as(f32, @floatFromInt(SELECTION_BORDER)),
                    .width = @as(f32, @floatFromInt(item.display_width + 2 * SELECTION_BORDER)),
                    .height = @as(f32, @floatFromInt(item_full_height + 2 * SELECTION_BORDER)),
                };
                rl.DrawRectangleRounded(highlight_rect, ROUNDNESS, 5, HIGHLIGHT_COLOR);
                rl.DrawRectangleRoundedLinesEx(highlight_rect, ROUNDNESS, 5, 2, HIGHLIGHT_COLOR_LINES);
            } else if (mouseover_index) |mi| {
                if (item_idx == mi) {
                    const highlight_rect = rl.Rectangle{
                        .x = x - @as(f32, @floatFromInt(SELECTION_BORDER)),
                        .y = y - @as(f32, @floatFromInt(SELECTION_BORDER)),
                        .width = @as(f32, @floatFromInt(item.display_width + 2 * SELECTION_BORDER)),
                        .height = @as(f32, @floatFromInt(item_full_height + 2 * SELECTION_BORDER)),
                    };
                    rl.DrawRectangleRounded(highlight_rect, ROUNDNESS, 5, HIGHLIGHT_COLOR_LESS);
                    rl.DrawRectangleRoundedLinesEx(highlight_rect, ROUNDNESS, 5, 2, HIGHLIGHT_COLOR_LESS_LINES);
                }
            }

            // Vertically center thumbnail within the item_height cell area.
            // For items shorter than item_height (wide/short windows constrained
            // by MAX_THUMBNAIL_WIDTH), this centers the preview in the cell.
            const thumb_y = y + @as(f32, @floatFromInt((layout.item_height - item.display_height) / 2));

            const dest_rect = rl.Rectangle{
                .x = x,
                .y = thumb_y,
                .width = @floatFromInt(item.display_width),
                .height = @floatFromInt(item.display_height),
            };

            const source_rect = rl.Rectangle{
                .x = 0,
                .y = 0,
                .width = @floatFromInt(item.thumbnail_texture.width),
                .height = @floatFromInt(item.thumbnail_texture.height),
            };

            if (item.thumbnail_ready) {
                // Use downsample shader for high-quality scaling if available
                if (downsample_shader) |shader| {
                    shader.begin(source_rect.width, source_rect.height, dest_rect.width, dest_rect.height);
                    rl.DrawTexturePro(item.thumbnail_texture, source_rect, dest_rect, rl.Vector2{ .x = 0, .y = 0 }, 0, rl.WHITE);
                    shader.end();
                } else {
                    rl.DrawTexturePro(item.thumbnail_texture, source_rect, dest_rect, rl.Vector2{ .x = 0, .y = 0 }, 0, rl.WHITE);
                }
            } else if (item.cached_snapshot) |snapshot| {
                // Show cached snapshot of last-known thumbnail while reacquiring.
                // Negate height to flip Y — raylib RenderTextures are rendered bottom-up.
                const snap_src = rl.Rectangle{
                    .x = 0,
                    .y = 0,
                    .width = @floatFromInt(snapshot.texture.width),
                    .height = -@as(f32, @floatFromInt(snapshot.texture.height)),
                };
                rl.DrawTexturePro(snapshot.texture, snap_src, dest_rect, rl.Vector2{ .x = 0, .y = 0 }, 0, rl.WHITE);
            } else {
                const fallback_bg = rl.Color{ .r = 0x18, .g = 0x18, .b = 0x18, .a = 230 };
                rl.DrawRectangleRounded(dest_rect, 0.06, 6, fallback_bg);

                if (item.icon_texture) |icon_tex| {
                    const thumb_h: f32 = @floatFromInt(item.display_height);
                    const thumb_w: f32 = @floatFromInt(item.display_width);
                    const icon_size = thumb_h * 0.42;
                    const icon_x = x + (thumb_w - icon_size) / 2.0;
                    const icon_y = thumb_y + (thumb_h - icon_size) / 2.0;
                    const icon_src = rl.Rectangle{
                        .x = 0,
                        .y = 0,
                        .width = @floatFromInt(icon_tex.width),
                        .height = @floatFromInt(icon_tex.height),
                    };
                    const icon_dst = rl.Rectangle{
                        .x = icon_x,
                        .y = icon_y,
                        .width = icon_size,
                        .height = icon_size,
                    };
                    rl.DrawTexturePro(icon_tex, icon_src, icon_dst, rl.Vector2{ .x = 0, .y = 0 }, 0, rl.WHITE);
                }
            }

            drawWindowWorkspaceBadge(font, workspace_names, item.workspace, x, thumb_y, item.display_width);

            // Draw icon overlay at bottom-center of grid cell (when live texture or cached snapshot is shown).
            // Uses item_height (not display_height) so the icon stays a consistent size
            // even for wide/short windows that have a smaller display_height.
            if ((item.thumbnail_ready or item.cached_snapshot != null) and item.icon_texture != null) {
                const icon_tex = item.icon_texture.?;
                const cell_h: f32 = @floatFromInt(layout.item_height);
                const thumb_w: f32 = @floatFromInt(item.display_width);
                const icon_size = cell_h * ICON_HEIGHT_RATIO;
                const icon_x = x + (thumb_w - icon_size) / 2.0;
                const icon_y = y + cell_h - icon_size + (cell_h * ICON_BOTTOM_OVERHANG);
                const icon_src = rl.Rectangle{
                    .x = 0,
                    .y = 0,
                    .width = @floatFromInt(icon_tex.width),
                    .height = @floatFromInt(icon_tex.height),
                };
                const icon_dst = rl.Rectangle{
                    .x = icon_x,
                    .y = icon_y,
                    .width = icon_size,
                    .height = icon_size,
                };
                rl.DrawTexturePro(icon_tex, icon_src, icon_dst, rl.Vector2{ .x = 0, .y = 0 }, 0, rl.WHITE);
            }

            // Title is always positioned at the bottom of the cell
            const title_y = y + @as(f32, @floatFromInt(layout.item_height + TITLE_SPACING));
            drawTruncatedText(font, item.title, x, title_y, @floatFromInt(TITLE_FONT_SIZE), @floatFromInt(item.display_width), TITLE_COLOR);

            x += @as(f32, @floatFromInt(item.display_width + SPACING));
            item_idx += 1;
        }
    }
}
