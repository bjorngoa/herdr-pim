//! Human (table) and machine (JSON) output for role rows.
const std = @import("std");
const rows_mod = @import("../domain/rows.zig");
const time = @import("../domain/time.zig");
const text_mod = @import("../present/text.zig");
const sanitize = text_mod.sanitize;
const displayWidth = text_mod.displayWidth;

pub const Style = struct {
    color: bool = false,
};

const headers = [_][]const u8{ "STATE", "ROLE", "SCOPE", "SUBSCRIPTION", "EXPIRES" };
const column_count = headers.len;

/// Writes an aligned table. Strings from Azure are sanitized so they cannot
/// inject terminal control sequences.
pub fn writeTable(arena: std.mem.Allocator, w: *std.Io.Writer, rows: []const rows_mod.Row, now: i64, style: Style) !void {
    const cells = try arena.alloc([column_count][]const u8, rows.len);
    var widths: [column_count]usize = undefined;
    for (headers, &widths) |h, *width| width.* = h.len;

    for (rows, cells) |row, *cell| {
        cell.* = .{
            stateLabel(row.state),
            try sanitize(arena, row.eligibility.role_name),
            try sanitize(arena, row.eligibility.scope_name),
            try sanitize(arena, row.subscription_name),
            try expires(arena, row, now),
        };
        for (cell.*, &widths) |text, *width| width.* = @max(width.*, displayWidth(text));
    }

    try writeRow(w, headers, widths, null, style);
    for (rows, cells) |row, cell| try writeRow(w, cell, widths, row.state, style);
}

const JsonRow = struct {
    state: rows_mod.State,
    role: []const u8,
    scope: []const u8,
    scopeName: []const u8,
    subscription: []const u8,
    expiresAt: ?[]const u8 = null,
    expiresInSeconds: ?i64 = null,
};

pub fn writeJson(arena: std.mem.Allocator, w: *std.Io.Writer, rows: []const rows_mod.Row, now: i64) !void {
    const out = try arena.alloc(JsonRow, rows.len);
    for (rows, out) |row, *dst| {
        dst.* = .{
            .state = row.state,
            .role = row.eligibility.role_name,
            .scope = row.eligibility.scope,
            .scopeName = row.eligibility.scope_name,
            .subscription = row.subscription_name,
        };
        if (row.active_until) |until| {
            const buf = try arena.create([20]u8);
            dst.expiresAt = time.formatRfc3339(until, buf);
            dst.expiresInSeconds = @max(0, until - now);
        }
    }
    try std.json.Stringify.value(out, .{ .whitespace = .indent_2, .emit_null_optional_fields = false }, w);
    try w.writeByte('\n');
}

fn writeRow(w: *std.Io.Writer, cells: [column_count][]const u8, widths: [column_count]usize, state: ?rows_mod.State, style: Style) !void {
    var last: usize = 0;
    for (cells, 0..) |text, i| if (text.len > 0) {
        last = i;
    };
    for (cells[0 .. last + 1], widths[0 .. last + 1], 0..) |text, width, i| {
        const color = if (style.color and i == 0) if (state) |s| stateColor(s) else "\x1b[1m" else "";
        try w.writeAll(color);
        try w.writeAll(text);
        if (color.len > 0) try w.writeAll("\x1b[0m");
        if (i < last) try w.splatByteAll(' ', width - displayWidth(text) + 2);
    }
    try w.writeByte('\n');
}

fn stateLabel(state: rows_mod.State) []const u8 {
    return switch (state) {
        .active => "● active",
        .pending => "◐ pending",
        .eligible => "○ eligible",
    };
}

fn stateColor(state: rows_mod.State) []const u8 {
    return switch (state) {
        .active => "\x1b[32m",
        .pending => "\x1b[33m",
        .eligible => "\x1b[2m",
    };
}

fn expires(arena: std.mem.Allocator, row: rows_mod.Row, now: i64) ![]const u8 {
    if (row.state != .active) return "";
    const until = row.active_until orelse return "-";
    const buf = try arena.create([16]u8);
    return time.formatRemaining(until - now, buf);
}

const testing = std.testing;

fn testRow(state: rows_mod.State, scope_name: []const u8, until: ?i64) rows_mod.Row {
    return .{
        .eligibility = .{
            .schedule_id = "sched",
            .scope = "/subscriptions/s/resourceGroups/x",
            .scope_name = scope_name,
            .role_definition_id = "r",
            .role_name = "Owner",
        },
        .subscription_name = "Sub",
        .state = state,
        .active_until = until,
    };
}

test "writeTable aligns columns and shows remaining time" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.Io.Writer.Allocating = .init(arena);

    const rows = [_]rows_mod.Row{ testRow(.active, "rg-long-name", 3600 + 300), testRow(.eligible, "rg", null) };
    try writeTable(arena, &out.writer, &rows, 0, .{});

    try testing.expectEqualStrings(
        \\STATE       ROLE   SCOPE         SUBSCRIPTION  EXPIRES
        \\● active    Owner  rg-long-name  Sub           1h05m
        \\○ eligible  Owner  rg            Sub
        \\
    , out.written());
}

test "writeTable colours only the state column when enabled" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.Io.Writer.Allocating = .init(arena);
    try writeTable(arena, &out.writer, &.{testRow(.pending, "rg", null)}, 0, .{ .color = true });
    try testing.expect(std.mem.indexOf(u8, out.written(), "\x1b[33m◐ pending\x1b[0m") != null);
}

test "writeJson emits machine-readable rows" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.Io.Writer.Allocating = .init(arena);
    try writeJson(arena, &out.writer, &.{testRow(.active, "rg", 120)}, 20);

    const Parsed = []const struct { state: []const u8, scopeName: []const u8, expiresAt: []const u8, expiresInSeconds: i64 };
    const parsed = try std.json.parseFromSliceLeaky(Parsed, arena, out.written(), .{ .ignore_unknown_fields = true });
    try testing.expectEqualStrings("active", parsed[0].state);
    try testing.expectEqualStrings("1970-01-01T00:02:00Z", parsed[0].expiresAt);
    try testing.expectEqual(@as(i64, 100), parsed[0].expiresInSeconds);
}
