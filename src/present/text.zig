//! Text safety helpers for anything shown in a terminal.
const std = @import("std");

/// Replaces C0/C1 control characters and invalid UTF-8 with `?`.
/// Returns `s` itself when it is already safe.
pub fn sanitize(arena: std.mem.Allocator, s: []const u8) std.mem.Allocator.Error![]const u8 {
    if (isSafe(s)) return s;
    var out: std.Io.Writer.Allocating = .init(arena);
    writeSanitized(&out.writer, s) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// Streaming form of `sanitize`, for writing untrusted text without allocating.
pub fn writeSanitized(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    if (isSafe(s)) return w.writeAll(s);
    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch {
            try w.writeByte('?');
            i += 1;
            continue;
        };
        if (i + len > s.len) {
            try w.writeByte('?');
            i += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(s[i .. i + len]) catch {
            try w.writeByte('?');
            i += 1;
            continue;
        };
        if (isControl(cp)) try w.writeByte('?') else try w.writeAll(s[i .. i + len]);
        i += len;
    }
}

fn isSafe(s: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(s)) return false;
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepoint()) |cp| if (isControl(cp)) return false;
    return true;
}

fn isControl(cp: u21) bool {
    return cp < 0x20 or (cp >= 0x7f and cp <= 0x9f);
}

/// Codepoint count; adequate for the Latin names Azure returns.
pub fn displayWidth(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

/// Truncates to at most `max` codepoints, appending `…` when shortened.
pub fn truncate(arena: std.mem.Allocator, s: []const u8, max: usize) ![]const u8 {
    if (displayWidth(s) <= max) return s;
    if (max == 0) return "";
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    var kept: usize = 0;
    var end: usize = 0;
    while (kept + 1 < max) : (kept += 1) {
        const cp = it.nextCodepointSlice() orelse break;
        end += cp.len;
    }
    return std.mem.concat(arena, u8, &.{ s[0..end], "…" });
}

const testing = std.testing;

test "sanitize neutralises control sequences" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const safe = "rg-ø-ok";
    try testing.expect((try sanitize(arena, safe)).ptr == safe.ptr);
    try testing.expectEqualStrings("?]0;pwned?", try sanitize(arena, "\x1b]0;pwned\x07"));
    try testing.expectEqualStrings("a?b", try sanitize(arena, "a\xc2\x9bb"));
    try testing.expectEqualStrings("a?b", try sanitize(arena, "a\xffb"));
}

test "writeSanitized streams the same replacement" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeSanitized(&out.writer, "ok \x1b[2Jcleared\xff");
    try testing.expectEqualStrings("ok ?[2Jcleared?", out.written());
}

test "truncate shortens by codepoints with an ellipsis" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("short", try truncate(arena, "short", 10));
    try testing.expectEqualStrings("abcd…", try truncate(arena, "abcdefgh", 5));
    try testing.expectEqualStrings("øø…", try truncate(arena, "øøøø", 3));
    try testing.expectEqualStrings("", try truncate(arena, "abc", 0));
}
