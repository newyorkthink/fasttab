const std = @import("std");

fn sequenceLength(first: u8) usize {
    if (first < 0x80) return 1;
    if ((first & 0xE0) == 0xC0) return 2;
    if ((first & 0xF0) == 0xE0) return 3;
    if ((first & 0xF8) == 0xF0) return 4;
    return 0;
}

fn isContinuation(byte: u8) bool {
    return (byte & 0xC0) == 0x80;
}

fn decodeCodepoint(bytes: []const u8) ?u21 {
    if (bytes.len == 0) return null;
    const cp: u32 = switch (bytes.len) {
        1 => bytes[0],
        2 => (@as(u32, bytes[0] & 0x1F) << 6) |
            @as(u32, bytes[1] & 0x3F),
        3 => (@as(u32, bytes[0] & 0x0F) << 12) |
            (@as(u32, bytes[1] & 0x3F) << 6) |
            @as(u32, bytes[2] & 0x3F),
        4 => (@as(u32, bytes[0] & 0x07) << 18) |
            (@as(u32, bytes[1] & 0x3F) << 12) |
            (@as(u32, bytes[2] & 0x3F) << 6) |
            @as(u32, bytes[3] & 0x3F),
        else => return null,
    };

    const minimum: u32 = switch (bytes.len) {
        1 => 0,
        2 => 0x80,
        3 => 0x800,
        4 => 0x10000,
        else => unreachable,
    };
    if (cp < minimum or cp > 0x10FFFF) return null;
    if (cp >= 0xD800 and cp <= 0xDFFF) return null;
    return @intCast(cp);
}

fn isPrivateUse(codepoint: u21) bool {
    return (codepoint >= 0xE000 and codepoint <= 0xF8FF) or
        (codepoint >= 0xF0000 and codepoint <= 0xFFFFD) or
        (codepoint >= 0x100000 and codepoint <= 0x10FFFD);
}

fn shouldReplace(codepoint: u21) bool {
    return isPrivateUse(codepoint) or
        codepoint == 0xFFFD or
        codepoint >= 0x1F000;
}

fn appendSeparator(output: []u8, output_index: *usize, separator_written: *bool) void {
    if (separator_written.* or output_index.* >= output.len) return;
    output[output_index.*] = '|';
    output_index.* += 1;
    separator_written.* = true;
}

/// Copy display text into `output`, replacing invalid UTF-8, private-use glyphs
/// (including Nerd Font / Powerline symbols), and supplementary pictographs with
/// a plain separator that is guaranteed to exist in the loaded UI font.
pub fn sanitizeDisplayText(text: []const u8, output: []u8) []const u8 {
    var input_index: usize = 0;
    var output_index: usize = 0;
    var separator_written = false;

    while (input_index < text.len and output_index < output.len) {
        const length = sequenceLength(text[input_index]);
        if (length == 0 or input_index + length > text.len) {
            appendSeparator(output, &output_index, &separator_written);
            input_index += 1;
            continue;
        }

        var valid = true;
        var i: usize = 1;
        while (i < length) : (i += 1) {
            if (!isContinuation(text[input_index + i])) {
                valid = false;
                break;
            }
        }
        if (!valid) {
            appendSeparator(output, &output_index, &separator_written);
            input_index += 1;
            continue;
        }

        const sequence = text[input_index .. input_index + length];
        const codepoint = decodeCodepoint(sequence) orelse {
            appendSeparator(output, &output_index, &separator_written);
            input_index += length;
            continue;
        };

        if (shouldReplace(codepoint)) {
            appendSeparator(output, &output_index, &separator_written);
            input_index += length;
            continue;
        }

        if (codepoint < 0x20 and codepoint != '\t') {
            if (output_index < output.len) {
                output[output_index] = ' ';
                output_index += 1;
            }
            separator_written = false;
            input_index += length;
            continue;
        }

        if (output_index + length > output.len) break;
        @memcpy(output[output_index .. output_index + length], sequence);
        output_index += length;
        input_index += length;
        separator_written = false;
    }

    return output[0..output_index];
}

comptime {
    _ = std;
}
