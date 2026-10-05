//! RFC 3339 timestamps (as returned by Azure Resource Manager) and compact
//! human-readable durations. All instants are Unix seconds (UTC).
const std = @import("std");

pub const ParseError = error{InvalidTimestamp};

/// Parses `YYYY-MM-DDTHH:MM:SS[.fraction](Z|±HH:MM)` into Unix seconds.
/// Fractional seconds of any length are accepted and truncated.
pub fn parseRfc3339(s: []const u8) ParseError!i64 {
    if (s.len < 20) return error.InvalidTimestamp;
    if (s[4] != '-' or s[7] != '-' or s[13] != ':' or s[16] != ':') return error.InvalidTimestamp;
    if (s[10] != 'T' and s[10] != 't' and s[10] != ' ') return error.InvalidTimestamp;

    const year = try digits(s[0..4]);
    const month = try digits(s[5..7]);
    const day = try digits(s[8..10]);
    const hour = try digits(s[11..13]);
    const minute = try digits(s[14..16]);
    const second = try digits(s[17..19]);
    if (month < 1 or month > 12 or day < 1 or day > daysInMonth(year, month)) return error.InvalidTimestamp;
    if (hour > 23 or minute > 59 or second > 60) return error.InvalidTimestamp;

    var i: usize = 19;
    if (s[i] == '.') {
        i += 1;
        const start = i;
        while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
        if (i == start) return error.InvalidTimestamp;
    }
    if (i >= s.len) return error.InvalidTimestamp;

    const offset_seconds: i64 = switch (s[i]) {
        'Z', 'z' => blk: {
            if (i + 1 != s.len) return error.InvalidTimestamp;
            break :blk 0;
        },
        '+', '-' => blk: {
            const rest = s[i + 1 ..];
            if (rest.len != 5 or rest[2] != ':') return error.InvalidTimestamp;
            const oh = try digits(rest[0..2]);
            const om = try digits(rest[3..5]);
            if (oh > 23 or om > 59) return error.InvalidTimestamp;
            const magnitude = oh * 3600 + om * 60;
            break :blk if (s[i] == '+') magnitude else -magnitude;
        },
        else => return error.InvalidTimestamp,
    };

    const days = daysFromCivil(year, month, day);
    return days * 86400 + hour * 3600 + minute * 60 + second - offset_seconds;
}

/// Formats Unix seconds (>= 0) as `YYYY-MM-DDTHH:MM:SSZ`.
pub fn formatRfc3339(unix: i64, buf: *[20]u8) []const u8 {
    std.debug.assert(unix >= 0);
    const days = @divFloor(unix, 86400);
    const secs_of_day: u64 = @intCast(@mod(unix, 86400));
    const civil = civilFromDays(days);
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        @as(u64, @intCast(civil.year)),
        @as(u64, @intCast(civil.month)),
        @as(u64, @intCast(civil.day)),
        secs_of_day / 3600,
        (secs_of_day % 3600) / 60,
        secs_of_day % 60,
    }) catch unreachable;
}

/// Formats a remaining duration compactly: `<1m`, `42m`, `3h05m`, `2d4h`.
/// Non-positive durations are formatted as `0m`.
pub fn formatRemaining(seconds: i64, buf: *[16]u8) []const u8 {
    if (seconds <= 0) return "0m";
    if (seconds < 60) return "<1m";
    const minutes: u64 = @intCast(@divFloor(seconds, 60));
    const out = if (minutes < 60)
        std.fmt.bufPrint(buf, "{d}m", .{minutes})
    else if (minutes < 24 * 60)
        std.fmt.bufPrint(buf, "{d}h{d:0>2}m", .{ minutes / 60, minutes % 60 })
    else
        std.fmt.bufPrint(buf, "{d}d{d}h", .{ minutes / (24 * 60), (minutes / 60) % 24 });
    return out catch unreachable;
}

fn digits(s: []const u8) ParseError!i64 {
    var value: i64 = 0;
    for (s) |c| {
        if (!std.ascii.isDigit(c)) return error.InvalidTimestamp;
        value = value * 10 + (c - '0');
    }
    return value;
}

fn isLeapYear(year: i64) bool {
    return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}

fn daysInMonth(year: i64, month: i64) i64 {
    return switch (month) {
        2 => if (isLeapYear(year)) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}

/// Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's algorithm).
fn daysFromCivil(year: i64, month: i64, day: i64) i64 {
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = if (month > 2) month - 3 else month + 9;
    const doy = @divFloor(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

const Civil = struct { year: i64, month: i64, day: i64 };

fn civilFromDays(days: i64) Civil {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const day = doy - @divFloor(153 * mp + 2, 5) + 1;
    const month = if (mp < 10) mp + 3 else mp - 9;
    return .{ .year = yoe + era * 400 + @intFromBool(month <= 2), .month = month, .day = day };
}

const testing = std.testing;

test "parseRfc3339 accepts ARM timestamp variants" {
    try testing.expectEqual(@as(i64, 0), try parseRfc3339("1970-01-01T00:00:00Z"));
    try testing.expectEqual(@as(i64, 1820386673), try parseRfc3339("2027-09-08T06:57:53.62Z"));
    try testing.expectEqual(@as(i64, 1787221838), try parseRfc3339("2026-08-20T10:30:38.7177115+00:00"));
    try testing.expectEqual(@as(i64, 1787221838 - 7200), try parseRfc3339("2026-08-20T10:30:38+02:00"));
    try testing.expectEqual(@as(i64, 951782400), try parseRfc3339("2000-02-29T00:00:00Z"));
}

test "parseRfc3339 rejects malformed input" {
    const bad = [_][]const u8{
        "",
        "2026-08-20",
        "2026-08-20T10:30:38",
        "2026-13-01T00:00:00Z",
        "2026-02-30T00:00:00Z",
        "2026-08-20T24:00:00Z",
        "2026-08-20T10:30:38.Z",
        "2026-08-20T10:30:38+0200",
        "2026-08-20T10:30:38Zjunk",
        "2026/08/20T10:30:38Z",
    };
    for (bad) |s| try testing.expectError(error.InvalidTimestamp, parseRfc3339(s));
}

test "formatRfc3339 round-trips" {
    var buf: [20]u8 = undefined;
    for ([_]i64{ 0, 951782400, 1787221838, 1820386673 }) |t| {
        try testing.expectEqual(t, try parseRfc3339(formatRfc3339(t, &buf)));
    }
    try testing.expectEqualStrings("2027-09-08T06:57:53Z", formatRfc3339(1820386673, &buf));
}

test "formatRemaining picks a compact unit" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("0m", formatRemaining(-5, &buf));
    try testing.expectEqualStrings("<1m", formatRemaining(59, &buf));
    try testing.expectEqualStrings("42m", formatRemaining(42 * 60 + 30, &buf));
    try testing.expectEqualStrings("3h05m", formatRemaining(3 * 3600 + 5 * 60, &buf));
    try testing.expectEqualStrings("2d4h", formatRemaining(2 * 86400 + 4 * 3600 + 59, &buf));
}
