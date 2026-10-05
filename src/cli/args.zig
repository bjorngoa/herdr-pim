//! Command-line parsing. Pure: no I/O, so every path is unit-testable.
const std = @import("std");
const duration = @import("../domain/duration.zig");

pub const CachePolicy = enum {
    /// Use the cache if fresh enough, else fetch.
    auto,
    /// Always fetch.
    refresh,
    /// Never fetch; fail if there is no cache.
    cached,
};

pub const default_duration_min: u32 = 8 * 60;

pub const List = struct {
    terms: []const []const u8 = &.{},
    json: bool = false,
    cache: CachePolicy = .auto,
};

pub const Status = struct {
    cache: CachePolicy = .auto,
    /// Raise herdr notifications for expiring, expired and newly active roles.
    notify: bool = false,
    /// Refresh from Azure when the cache is older than this.
    max_age_s: u32 = 300,
};

pub const Up = struct {
    terms: []const []const u8,
    all: bool = false,
    duration_min: u32 = default_duration_min,
    justification: ?[]const u8 = null,
    wait: bool = true,
};

pub const Down = struct {
    terms: []const []const u8,
    all: bool = false,
    wait: bool = true,
};

pub const Pick = struct {
    /// Initial filter terms.
    terms: []const []const u8 = &.{},
    duration_min: u32 = default_duration_min,
    /// Chosen because no command was given; falls back to `ls` without a terminal.
    implicit: bool = false,
};

pub const Command = union(enum) {
    pick: Pick,
    list: List,
    status: Status,
    up: Up,
    down: Down,
    help,
    version,
};

pub const ParseError = error{ UnknownCommand, UnknownOption, MissingValue, InvalidValue, MissingFilter };

pub const Diagnostics = struct {
    /// The argument that caused the error.
    arg: []const u8 = "",
};

/// Parses arguments (excluding the program name). Strings in the result
/// borrow from `args`; lists are allocated with `arena`.
pub fn parse(arena: std.mem.Allocator, args: []const []const u8, diag: *Diagnostics) (ParseError || std.mem.Allocator.Error)!Command {
    if (args.len == 0) return .{ .pick = .{ .implicit = true } };
    const name = args[0];
    var cursor: Cursor = .{ .args = args[1..], .diag = diag };
    diag.arg = name;
    if (eql(name, "pick") or eql(name, "ui")) return .{ .pick = try parsePick(arena, &cursor) };
    if (eql(name, "ls") or eql(name, "list")) return .{ .list = try parseList(arena, &cursor) };
    if (eql(name, "status")) return .{ .status = try parseStatus(&cursor) };
    if (eql(name, "up") or eql(name, "activate")) return .{ .up = parseUp(arena, &cursor) catch |err| return blame(err, name, diag) };
    if (eql(name, "down") or eql(name, "deactivate")) return .{ .down = parseDown(arena, &cursor) catch |err| return blame(err, name, diag) };
    if (eql(name, "help") or eql(name, "-h") or eql(name, "--help")) return .help;
    if (eql(name, "version") or eql(name, "-V") or eql(name, "--version")) return .version;
    return error.UnknownCommand;
}

fn parseList(arena: std.mem.Allocator, c: *Cursor) !List {
    var list: List = .{};
    var terms: std.ArrayList([]const u8) = .empty;
    while (c.next()) |arg| {
        if (c.isTerm(arg)) {
            try terms.append(arena, arg);
        } else if (eql(arg, "--json")) {
            list.json = true;
        } else if (cachePolicy(arg)) |policy| {
            list.cache = policy;
        } else return c.unknown(arg);
    }
    list.terms = try terms.toOwnedSlice(arena);
    return list;
}

fn parsePick(arena: std.mem.Allocator, c: *Cursor) !Pick {
    var pick: Pick = .{};
    var terms: std.ArrayList([]const u8) = .empty;
    while (c.next()) |arg| {
        if (c.isTerm(arg)) {
            try terms.append(arena, arg);
        } else if (try c.value(arg, "--duration", "-d")) |v| {
            pick.duration_min = duration.parse(v) catch return c.invalid(v);
        } else return c.unknown(arg);
    }
    pick.terms = try terms.toOwnedSlice(arena);
    return pick;
}

fn parseStatus(c: *Cursor) ParseError!Status {
    var status: Status = .{};
    while (c.next()) |arg| {
        if (cachePolicy(arg)) |policy| {
            status.cache = policy;
        } else if (eql(arg, "--notify")) {
            status.notify = true;
        } else if (try c.value(arg, "--max-age", null)) |v| {
            status.max_age_s = std.fmt.parseInt(u32, v, 10) catch return c.invalid(v);
        } else return c.unknown(arg);
    }
    return status;
}

fn parseUp(arena: std.mem.Allocator, c: *Cursor) !Up {
    var up: Up = .{ .terms = &.{} };
    var terms: std.ArrayList([]const u8) = .empty;
    while (c.next()) |arg| {
        if (c.isTerm(arg)) {
            try terms.append(arena, arg);
        } else if (eql(arg, "--all")) {
            up.all = true;
        } else if (eql(arg, "--no-wait")) {
            up.wait = false;
        } else if (try c.value(arg, "--duration", "-d")) |v| {
            up.duration_min = duration.parse(v) catch return c.invalid(v);
        } else if (try c.value(arg, "--justification", "-j")) |v| {
            up.justification = v;
        } else return c.unknown(arg);
    }
    up.terms = try terms.toOwnedSlice(arena);
    if (up.terms.len == 0) return error.MissingFilter;
    return up;
}

fn parseDown(arena: std.mem.Allocator, c: *Cursor) !Down {
    var down: Down = .{ .terms = &.{} };
    var terms: std.ArrayList([]const u8) = .empty;
    while (c.next()) |arg| {
        if (c.isTerm(arg)) {
            try terms.append(arena, arg);
        } else if (eql(arg, "--all")) {
            down.all = true;
        } else if (eql(arg, "--no-wait")) {
            down.wait = false;
        } else return c.unknown(arg);
    }
    down.terms = try terms.toOwnedSlice(arena);
    if (down.terms.len == 0 and !down.all) return error.MissingFilter;
    return down;
}

/// A missing filter is the command's fault, not the last argument's.
fn blame(err: (ParseError || std.mem.Allocator.Error), command: []const u8, diag: *Diagnostics) (ParseError || std.mem.Allocator.Error) {
    if (err == error.MissingFilter) diag.arg = command;
    return err;
}

fn cachePolicy(arg: []const u8) ?CachePolicy {
    if (eql(arg, "--refresh")) return .refresh;
    if (eql(arg, "--cached")) return .cached;
    return null;
}

/// Walks arguments, treating everything after `--` as positional.
const Cursor = struct {
    args: []const []const u8,
    index: usize = 0,
    only_terms: bool = false,
    diag: *Diagnostics,

    fn next(c: *Cursor) ?[]const u8 {
        while (c.index < c.args.len) {
            const arg = c.args[c.index];
            c.index += 1;
            if (!c.only_terms and eql(arg, "--")) {
                c.only_terms = true;
                continue;
            }
            c.diag.arg = arg;
            return arg;
        }
        return null;
    }

    fn isTerm(c: *const Cursor, arg: []const u8) bool {
        return c.only_terms or !std.mem.startsWith(u8, arg, "-");
    }

    /// If `arg` is `long`/`short`, returns its value from `--long=v` or the
    /// next argument; otherwise null.
    fn value(c: *Cursor, arg: []const u8, comptime long: []const u8, comptime short: ?[]const u8) ParseError!?[]const u8 {
        if (c.only_terms) return null;
        if (std.mem.startsWith(u8, arg, long ++ "=")) return arg[long.len + 1 ..];
        const matches = eql(arg, long) or (if (short) |s| eql(arg, s) else false);
        if (!matches) return null;
        if (c.index == c.args.len) return error.MissingValue;
        defer c.index += 1;
        c.diag.arg = c.args[c.index];
        return c.args[c.index];
    }

    fn unknown(c: *Cursor, arg: []const u8) ParseError {
        c.diag.arg = arg;
        return error.UnknownOption;
    }

    fn invalid(c: *Cursor, v: []const u8) ParseError {
        c.diag.arg = v;
        return error.InvalidValue;
    }
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

const testing = std.testing;

fn parseFor(arena: std.mem.Allocator, args: []const []const u8) !Command {
    var diag: Diagnostics = .{};
    return parse(arena, args, &diag);
}

test "no arguments opens the picker implicitly" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const cmd = try parseFor(arena_state.allocator(), &.{});
    try testing.expect(cmd.pick.implicit);
    try testing.expectEqual(@as(usize, 0), cmd.pick.terms.len);
}

test "pick takes an initial filter and duration" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const cmd = try parseFor(arena_state.allocator(), &.{ "ui", "orders", "prod", "-d", "4h" });
    try testing.expect(!cmd.pick.implicit);
    try testing.expectEqual(@as(usize, 2), cmd.pick.terms.len);
    try testing.expectEqual(@as(u32, 240), cmd.pick.duration_min);
}

test "ls collects terms and flags" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const cmd = try parseFor(arena_state.allocator(), &.{ "ls", "orders", "--json", "prod", "--refresh", "--", "--literal" });
    try testing.expect(cmd.list.json);
    try testing.expectEqual(CachePolicy.refresh, cmd.list.cache);
    try testing.expectEqual(@as(usize, 3), cmd.list.terms.len);
    try testing.expectEqualStrings("--literal", cmd.list.terms[2]);
}

test "status parses max-age in both forms" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqual(@as(u32, 300), (try parseFor(arena, &.{"status"})).status.max_age_s);
    try testing.expectEqual(@as(u32, 60), (try parseFor(arena, &.{ "status", "--max-age", "60" })).status.max_age_s);
    try testing.expectEqual(@as(u32, 90), (try parseFor(arena, &.{ "status", "--max-age=90", "--cached" })).status.max_age_s);
    try testing.expectEqual(CachePolicy.cached, (try parseFor(arena, &.{ "status", "--cached" })).status.cache);
    try testing.expect((try parseFor(arena, &.{ "status", "--notify" })).status.notify);
}

test "up parses duration, justification and flags" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const defaults = (try parseFor(arena, &.{ "up", "rg-dev" })).up;
    try testing.expectEqual(default_duration_min, defaults.duration_min);
    try testing.expect(defaults.justification == null and defaults.wait and !defaults.all);

    const up = (try parseFor(arena, &.{ "activate", "rg", "-d", "1h30m", "--justification=fix prod", "--all", "--no-wait", "owner" })).up;
    try testing.expectEqual(@as(u32, 90), up.duration_min);
    try testing.expectEqualStrings("fix prod", up.justification.?);
    try testing.expect(up.all and !up.wait);
    try testing.expectEqual(@as(usize, 2), up.terms.len);

    const j = (try parseFor(arena, &.{ "up", "rg", "-j", "-starts-with-dash" })).up;
    try testing.expectEqualStrings("-starts-with-dash", j.justification.?);
}

test "down accepts --all without terms" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expect((try parseFor(arena, &.{ "down", "--all" })).down.all);
    try testing.expectEqualStrings("rg", (try parseFor(arena, &.{ "deactivate", "rg" })).down.terms[0]);
}

test "help and version aliases" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqual(Command.help, try parseFor(arena, &.{"--help"}));
    try testing.expectEqual(Command.version, try parseFor(arena, &.{"-V"}));
}

test "errors report the offending argument" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diagnostics = .{};

    try testing.expectError(error.UnknownCommand, parse(arena, &.{"elevate"}, &diag));
    try testing.expectEqualStrings("elevate", diag.arg);
    try testing.expectError(error.UnknownOption, parse(arena, &.{ "ls", "--nope" }, &diag));
    try testing.expectEqualStrings("--nope", diag.arg);
    try testing.expectError(error.MissingValue, parse(arena, &.{ "status", "--max-age" }, &diag));
    try testing.expectError(error.InvalidValue, parse(arena, &.{ "status", "--max-age=-1" }, &diag));
    try testing.expectEqualStrings("-1", diag.arg);
    try testing.expectError(error.InvalidValue, parse(arena, &.{ "up", "rg", "-d", "forever" }, &diag));
    try testing.expectEqualStrings("forever", diag.arg);
    try testing.expectError(error.MissingFilter, parse(arena, &.{ "up", "--all" }, &diag));
    try testing.expectEqualStrings("up", diag.arg);
    try testing.expectError(error.MissingFilter, parse(arena, &.{"down"}, &diag));
}
