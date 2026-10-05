//! One-line summary for status bars such as herdr's `tab_bar_right`.
const std = @import("std");
const rows_mod = @import("rows.zig");
const time = @import("time.zig");

pub const Summary = struct {
    active: usize = 0,
    pending: usize = 0,
    /// Earliest end among time-bound active rows.
    soonest_end: ?i64 = null,
};

pub fn summarize(rows: []const rows_mod.Row) Summary {
    var s: Summary = .{};
    for (rows) |r| switch (r.state) {
        .active => {
            s.active += 1;
            if (r.active_until) |end| s.soonest_end = if (s.soonest_end) |cur| @min(cur, end) else end;
        },
        .pending => s.pending += 1,
        .eligible => {},
    };
    return s;
}

/// Renders e.g. `PIM 2 · 3h05m`, `PIM 1 · 42m ◐1` or `PIM ◐1`.
/// Returns an empty string when nothing is active or pending, so the status
/// entry disappears.
pub fn formatLine(summary: Summary, now: i64, buf: *[64]u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    writeLine(&w, summary, now) catch unreachable; // 64 bytes always suffice.
    return w.buffered();
}

fn writeLine(w: *std.Io.Writer, summary: Summary, now: i64) std.Io.Writer.Error!void {
    if (summary.active == 0 and summary.pending == 0) return;
    try w.writeAll("PIM");
    if (summary.active > 0) {
        try w.print(" {d}", .{summary.active});
        if (summary.soonest_end) |end| {
            var buf: [16]u8 = undefined;
            try w.print(" · {s}", .{time.formatRemaining(end - now, &buf)});
        }
    }
    if (summary.pending > 0) try w.print(" ◐{d}", .{summary.pending});
}

const testing = std.testing;

fn row(state: rows_mod.State, until: ?i64) rows_mod.Row {
    return .{
        .eligibility = .{ .schedule_id = "", .scope = "", .scope_name = "", .role_definition_id = "", .role_name = "" },
        .subscription_name = "",
        .state = state,
        .active_until = until,
    };
}

test "summarize counts states and finds the soonest expiry" {
    const rows = [_]rows_mod.Row{ row(.active, 500), row(.active, 200), row(.active, null), row(.pending, null), row(.eligible, null) };
    const s = summarize(&rows);
    try testing.expectEqual(@as(usize, 3), s.active);
    try testing.expectEqual(@as(usize, 1), s.pending);
    try testing.expectEqual(@as(?i64, 200), s.soonest_end);
}

test "formatLine renders active, pending and empty states" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("", formatLine(.{}, 0, &buf));
    try testing.expectEqualStrings("PIM 2 · 3h05m", formatLine(.{ .active = 2, .soonest_end = 3 * 3600 + 300 }, 0, &buf));
    try testing.expectEqualStrings("PIM 1 · 42m ◐1", formatLine(.{ .active = 1, .pending = 1, .soonest_end = 42 * 60 }, 0, &buf));
    try testing.expectEqualStrings("PIM 1", formatLine(.{ .active = 1 }, 0, &buf));
    try testing.expectEqualStrings("PIM ◐2", formatLine(.{ .pending = 2 }, 0, &buf));
}
