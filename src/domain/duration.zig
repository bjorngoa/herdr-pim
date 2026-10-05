//! Activation durations: human input (`8h`, `90m`, `1h30m`) or ISO 8601
//! (`PT8H`, `PT1H30M`), held as whole minutes.
const std = @import("std");

pub const ParseError = error{InvalidDuration};

/// Upper bound accepted from users; Azure policies cap far lower.
pub const max_minutes: u32 = 7 * 24 * 60;

pub fn parse(text: []const u8) ParseError!u32 {
    if (text.len == 0) return error.InvalidDuration;
    const iso = std.ascii.startsWithIgnoreCase(text, "PT");
    const body = if (iso) text[2..] else text;
    if (body.len == 0) return error.InvalidDuration;

    var minutes: u64 = 0;
    var number: ?u64 = null;
    var last_unit: u8 = 0;
    for (body) |c| {
        if (std.ascii.isDigit(c)) {
            number = std.math.add(u64, std.math.mul(u64, number orelse 0, 10) catch return error.InvalidDuration, c - '0') catch
                return error.InvalidDuration;
            continue;
        }
        const n = number orelse return error.InvalidDuration;
        const unit = std.ascii.toLower(c);
        // Units must appear at most once and in h, m order.
        const factor: u64 = switch (unit) {
            'h' => if (last_unit == 0) 60 else return error.InvalidDuration,
            'm' => if (last_unit != 'm') 1 else return error.InvalidDuration,
            else => return error.InvalidDuration,
        };
        const scaled = std.math.mul(u64, n, factor) catch return error.InvalidDuration;
        minutes = std.math.add(u64, minutes, scaled) catch return error.InvalidDuration;
        last_unit = unit;
        number = null;
    }
    if (number != null or minutes == 0 or minutes > max_minutes) return error.InvalidDuration;
    return @intCast(minutes);
}

/// Formats as ISO 8601 for ARM, e.g. `PT8H`, `PT1H30M`, `PT45M`.
pub fn formatIso(minutes: u32, buf: *[16]u8) []const u8 {
    std.debug.assert(minutes > 0);
    var w: std.Io.Writer = .fixed(buf);
    w.writeAll("PT") catch unreachable;
    if (minutes / 60 > 0) w.print("{d}H", .{minutes / 60}) catch unreachable;
    if (minutes % 60 > 0) w.print("{d}M", .{minutes % 60}) catch unreachable;
    return w.buffered();
}

/// Formats for people, e.g. `8h`, `1h30m`, `45m`.
pub fn formatHuman(minutes: u32, buf: *[16]u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    if (minutes / 60 > 0) w.print("{d}h", .{minutes / 60}) catch unreachable;
    if (minutes % 60 > 0 or minutes == 0) w.print("{d}m", .{minutes % 60}) catch unreachable;
    return w.buffered();
}

pub const Clamped = struct {
    minutes: u32,
    /// True when the request was shortened to fit the policy.
    clamped: bool,
};

pub fn clamp(requested: u32, policy_max: ?u32) Clamped {
    const max = policy_max orelse return .{ .minutes = requested, .clamped = false };
    return if (requested > max) .{ .minutes = max, .clamped = true } else .{ .minutes = requested, .clamped = false };
}

const testing = std.testing;

test "parse accepts human and ISO forms" {
    try testing.expectEqual(@as(u32, 480), try parse("8h"));
    try testing.expectEqual(@as(u32, 90), try parse("90m"));
    try testing.expectEqual(@as(u32, 90), try parse("1h30m"));
    try testing.expectEqual(@as(u32, 480), try parse("PT8H"));
    try testing.expectEqual(@as(u32, 90), try parse("pt1h30m"));
    try testing.expectEqual(@as(u32, 45), try parse("PT45M"));
}

test "parse rejects malformed or out-of-range durations" {
    const bad = [_][]const u8{ "", "8", "h", "PT", "0h", "1m1h", "1h1h", "2m3m", "8d", "-1h", "1.5h", "99999999999999999999h", "999999999999999999h", "200h" };
    for (bad) |s| try testing.expectError(error.InvalidDuration, parse(s));
}

test "format round-trips" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("PT8H", formatIso(480, &buf));
    try testing.expectEqualStrings("PT1H30M", formatIso(90, &buf));
    try testing.expectEqualStrings("PT45M", formatIso(45, &buf));
    try testing.expectEqualStrings("8h", formatHuman(480, &buf));
    try testing.expectEqualStrings("1h30m", formatHuman(90, &buf));
    try testing.expectEqualStrings("45m", formatHuman(45, &buf));
    for ([_]u32{ 1, 45, 60, 90, 480 }) |m| try testing.expectEqual(m, try parse(formatIso(m, &buf)));
}

test "clamp respects the policy maximum" {
    try testing.expectEqual(Clamped{ .minutes = 480, .clamped = false }, clamp(480, null));
    try testing.expectEqual(Clamped{ .minutes = 240, .clamped = true }, clamp(480, 240));
    try testing.expectEqual(Clamped{ .minutes = 60, .clamped = false }, clamp(60, 240));
}
