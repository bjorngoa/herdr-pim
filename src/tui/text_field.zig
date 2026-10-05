//! Single-line, append-only text input with a fixed capacity. Edits keep the
//! contents valid UTF-8 and free of control characters.
const std = @import("std");

pub const TextField = struct {
    pub const capacity = 256;

    buf: [capacity]u8 = undefined,
    len: usize = 0,

    pub fn text(self: *const TextField) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn isEmpty(self: *const TextField) bool {
        return self.len == 0;
    }

    pub fn clear(self: *TextField) void {
        self.len = 0;
    }

    pub fn set(self: *TextField, s: []const u8) void {
        self.clear();
        self.insert(s);
    }

    /// Appends whole codepoints from `s` that fit; control characters and
    /// invalid UTF-8 are dropped.
    pub fn insert(self: *TextField, s: []const u8) void {
        var i: usize = 0;
        while (i < s.len) {
            const n = std.unicode.utf8ByteSequenceLength(s[i]) catch {
                i += 1;
                continue;
            };
            if (i + n > s.len) return;
            const cp = std.unicode.utf8Decode(s[i .. i + n]) catch {
                i += 1;
                continue;
            };
            defer i += n;
            if (cp < 0x20 or (cp >= 0x7f and cp <= 0x9f)) continue;
            if (self.len + n > capacity) return;
            @memcpy(self.buf[self.len .. self.len + n], s[i .. i + n]);
            self.len += n;
        }
    }

    /// Removes the last codepoint.
    pub fn backspace(self: *TextField) void {
        if (self.len == 0) return;
        var i = self.len - 1;
        while (i > 0 and self.buf[i] & 0xC0 == 0x80) i -= 1;
        self.len = i;
    }

    /// Removes trailing spaces, then the word before them.
    pub fn deleteWord(self: *TextField) void {
        while (self.len > 0 and self.buf[self.len - 1] == ' ') self.len -= 1;
        while (self.len > 0 and self.buf[self.len - 1] != ' ') self.backspace();
    }
};

const testing = std.testing;

test "insert, backspace and deleteWord respect codepoints" {
    var f: TextField = .{};
    f.insert("rg ø");
    try testing.expectEqualStrings("rg ø", f.text());
    f.backspace();
    try testing.expectEqualStrings("rg ", f.text());
    f.insert("prod  ");
    f.deleteWord();
    try testing.expectEqualStrings("rg ", f.text());
    f.deleteWord();
    try testing.expectEqualStrings("", f.text());
    f.backspace();
    try testing.expect(f.isEmpty());
}

test "insert drops control characters and invalid bytes" {
    var f: TextField = .{};
    f.insert("a\x1b[31mb\xffc\xc2\x9bd");
    try testing.expectEqualStrings("a[31mbcd", f.text());
}

test "insert stops at capacity without splitting codepoints" {
    var f: TextField = .{};
    f.set("x" ** (TextField.capacity - 1));
    f.insert("ø");
    try testing.expectEqual(TextField.capacity - 1, f.text().len);
    f.insert("y");
    try testing.expectEqual(TextField.capacity, f.text().len);
}
